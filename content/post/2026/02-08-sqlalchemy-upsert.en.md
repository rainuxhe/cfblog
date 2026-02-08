+++
date = '2026-02-08T16:20:18+08:00'
draft = false
title = 'Using UPSERT in SQLAlchemy'
description = "This article explains how to use UPSERT operations in SQLAlchemy with PostgreSQL and SQLite"
isCJKLanguage = false
categories = ["program"]
tags = ["python", "sqlalchemy", "postgres", "sqlite", "sql"]
keywords = [
    "python",
    "sqlalchemy",
    "postgres",
    "sqlite",
    "sql",
    "upsert",
]
slug = "sqlalchemy-upsert"
+++

## Introduction

Both SQLite and PostgreSQL support UPSERT operations, which means "update if exists, insert if not." The conflict column must have a unique constraint.

Syntax:

- PostgreSQL: `INSERT ... ON CONFLICT (column) DO UPDATE/NOTHING`
- SQLite: `INSERT ... ON CONFLICT(column) DO UPDATE/NOTHING` (note the parentheses position)

| Scenario | PostgreSQL | SQLite | Notes |
|---|---|---|---|
| **Basic UPSERT** | `ON CONFLICT (col) DO UPDATE SET ...` | `ON CONFLICT(col) DO UPDATE SET ...` | Slight difference in parentheses placement |
| **Conflict Ignore** | `ON CONFLICT (col) DO NOTHING` | `ON CONFLICT(col) DO NOTHING` | Same syntax |
| **Reference New Values** | `EXCLUDED.col` | `excluded.col` | PostgreSQL uses uppercase, SQLite uses lowercase |
| **Return Results** | `RETURNING *` | `RETURNING *` | Same syntax |
| **Conditional Update** | `WHERE condition` | WHERE not supported | SQLite limitation |

## Key Considerations

- The conflict column must have a unique constraint
- PostgreSQL and SQLite syntax is similar but has subtle differences. Pay attention when using raw SQL.
- SQLite does not support WHERE clauses in UPSERT operations; use CASE expressions or application-level filtering instead.
- SQLite version 3.35+ is required for RETURNING support.

## EXCLUDED and RETURNING

### EXCLUDED

`EXCLUDED` represents the new values that were intercepted due to a conflict.

```sql
INSERT INTO users (email, name, age)
VALUES ('test@example.com', 'New Name', 30)
ON CONFLICT (email) DO UPDATE SET
    name = EXCLUDED.name,   -- ← Reference new value "New Name"
    age = EXCLUDED.age      -- ← Reference new value 30
```

| Scenario | Expression | Meaning | Example Value |
| -------- | ---------- | ------- | ------------- |
| **Original Column** | `users.name` | **Current value** of conflicting row | "Old Name" |
| **New Value Column** | `EXCLUDED.name` | **New value** attempting to be inserted | "New Name" |
| **Combined Calculation** | `users.age + EXCLUDED.age` | Original value + New value | 25 + 30 = 55 |

**Example 1: Inventory Accumulation**

```sql
-- Product inventory accumulation: original stock 100 + new addition 50 = 150
INSERT INTO products (sku, stock)
VALUES ('IPHONE15', 50)
ON CONFLICT (sku) DO UPDATE SET
    stock = products.stock + EXCLUDED.stock  -- 100 + 50
RETURNING stock;
```

**Example 2: Update Only Non-NULL Fields**

```sql
-- If new value is NULL, preserve the original value
INSERT INTO users (email, name, age)
VALUES ('test@example.com', 'New Name', NULL)
ON CONFLICT (email) DO UPDATE SET
    name = COALESCE(EXCLUDED.name, users.name),  -- New Name
    age = COALESCE(EXCLUDED.age, users.age)      -- Preserve original age
```

**Example 3: Timestamp Updates**

```sql
-- Refresh updated_at on update
INSERT INTO users (email, name)
VALUES ('test@example.com', 'New Name')
ON CONFLICT (email) DO UPDATE SET
    name = EXCLUDED.name,
    updated_at = NOW()  -- PostgreSQL
    -- updated_at = CURRENT_TIMESTAMP  -- SQLite
```

### RETURNING

`RETURNING` is used to return operation results. It **directly returns specified columns** immediately after `INSERT`/`UPDATE`/`DELETE`, avoiding additional `SELECT` queries:

```sql
INSERT INTO users (email, name)
VALUES ('test@example.com', 'Zhang San')
RETURNING id, email, name, created_at;
```

**Example 1: Get ID Immediately After Insertion**

```python
# PostgreSQL / SQLite 3.35+
sql = text("""
    INSERT INTO users (email, name)
    VALUES (:email, :name)
    RETURNING id, email, created_at
""")

result = await session.execute(sql, {"email": "test@example.com", "name": "Zhang San"})
user = result.mappings().first()
print(user["id"])  # Get ID directly
```

**Example 2: Unified Return After UPSERT**

```sql
-- Return final state regardless of insert or update
INSERT INTO users (email, name, login_count)
VALUES ('test@example.com', 'Zhang San', 1)
ON CONFLICT (email) DO UPDATE SET
    name = EXCLUDED.name,
    login_count = users.login_count + 1  -- Increment login count
RETURNING 
    id,
    email,
    name,
    login_count,
    CASE 
        WHEN xmax = 0 THEN 'inserted'  -- PostgreSQL specific: xmax=0 indicates insertion
        ELSE 'updated'
    END AS action
```

**Example 3: Return All Results from Bulk Operations**

```sql
-- PostgreSQL supports bulk RETURNING
INSERT INTO users (email, name)
VALUES 
    ('a@example.com', 'A'),
    ('b@example.com', 'B')
ON CONFLICT (email) DO UPDATE SET
    name = EXCLUDED.name
RETURNING id, email, name;
```

Python handling for bulk returns:

```python
result = await session.execute(sql)
users = [dict(row) for row in result.mappings().all()]
# [{'id': 1, 'email': 'a@example.com', 'name': 'A'}, ...]
```

### Example: User Login Counter

```python
async def record_user_login(session: AsyncSession, email: str, name: str) -> dict:
    """
    User login counter:
    - New user: insert with login_count = 1
    - Existing user: update with login_count += 1
    - Return final state + operation type
    """
    sql = text("""
        INSERT INTO users (
            email, name, login_count, last_login, created_at
        ) VALUES (
            :email, :name, 1, :now, :now
        )
        ON CONFLICT (email) DO UPDATE SET
            name = EXCLUDED.name,                          -- Update username
            login_count = users.login_count + 1,           -- Increment login count
            last_login = EXCLUDED.last_login               -- Update last login time
        RETURNING
            id,
            email,
            name,
            login_count,
            last_login,
            created_at,
            CASE 
                WHEN xmax = 0 THEN 'inserted' 
                ELSE 'updated' 
            END AS action  -- PostgreSQL specific: distinguish insert/update
    """)
    
    now = datetime.utcnow()
    result = await session.execute(
        sql,
        {"email": email, "name": name, "now": now}
    )
    
    row = result.mappings().first()
    return dict(row) if row else None

# Usage example
user = await record_user_login(session, "test@example.com", "Zhang San")
print(f"{user['action']} user {user['email']} with {user['login_count']} logins")
# Output: inserted user test@example.com with 1 logins
# or: updated user test@example.com with 5 logins
```

## Example Data Model Classes

```python
from sqlalchemy import Column, Integer, String, UniqueConstraint
from sqlalchemy.orm import DeclarativeBase

class Base(DeclarativeBase):
    pass

class User(Base):
    __tablename__ = "users"
    
    id = Column(Integer, primary_key=True, autoincrement=True)
    email = Column(String(100), unique=True, nullable=False)  # Unique constraint
    name = Column(String(50))
    age = Column(Integer)
    balance = Column(Integer, default=0)
    
    __table_args__ = (
        UniqueConstraint("email", name="uq_users_email"),
    )

class Product(Base):
    __tablename__ = "products"
    
    id = Column(Integer, primary_key=True)
    sku = Column(String(50), unique=True, nullable=False)  # Unique SKU
    name = Column(String(100))
    stock = Column(Integer, default=0)
    price = Column(Integer)
```

## ORM Approach

Note the import path for `insert`.

### Basic Example

```python
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.dialects.sqlite import insert as sqlite_insert
from sqlalchemy import insert

async def upsert_user_orm(session: AsyncSession, user_data: dict) -> dict:
    """
    UPSERT user (ORM style)
    Update if email conflicts, otherwise insert
    """
    
    # Method 1: Use generic insert (recommended⭐)
    # SQLAlchemy automatically selects the correct syntax based on dialect
    stmt = (
        insert(User)
        .values(**user_data)
        .on_conflict_do_update(
            index_elements=["email"],  # Conflict detection column (unique constraint)
            set_={
                "name": user_data["name"],
                "age": user_data.get("age"),
                "updated_at": func.now()  # Assuming updated_at column exists
            }
        )
        .returning(User)  # Return the inserted/updated row
    )
    
    result = await session.execute(stmt)
    user = result.scalar_one()
    
    return {
        "id": user.id,
        "email": user.email,
        "name": user.name,
        "age": user.age
    }

async def upsert_user_ignore(session: AsyncSession, user_data: dict) -> bool:
    """
    UPSERT but ignore on conflict (DO NOTHING)
    """
    stmt = (
        insert(User)
        .values(**user_data)
        .on_conflict_do_nothing(
            index_elements=["email"]
        )
    )
    
    result = await session.execute(stmt)
    return result.rowcount > 0  # Return whether insertion was successful
```

### Conditional Updates: Update Only Specific Fields

```python
async def upsert_user_conditional(session: AsyncSession, user_data: dict) -> dict:
    """
    UPSERT: update only non-NULL fields on conflict
    """
    stmt = (
        insert(User)
        .values(**user_data)
        .on_conflict_do_update(
            index_elements=["email"],
            set_={
                "name": user_data["name"],
                # Condition: only update age if provided
                "age": user_data.get("age", User.age),  # Keep original value
            },
            # Optional: add WHERE condition
            where=User.email == user_data["email"]
        )
        .returning(User)
    )
    
    result = await session.execute(stmt)
    return result.mappings().first()
```

### Bulk UPSERT

```python
async def bulk_upsert_users(session: AsyncSession, users: list[dict]) -> int:
    """
    Bulk UPSERT users
    """
    stmt = (
        insert(User)
        .values(users)
        .on_conflict_do_update(
            index_elements=["email"],
            set_={
                "name": insert(User).excluded.name,  # Use excluded to reference new values
                "age": insert(User).excluded.age,
            }
        )
    )
    
    result = await session.execute(stmt)
    return result.rowcount
```

### Using EXCLUDED to Reference New Values

```python
async def upsert_product_with_stock(session: AsyncSession, product_data: dict) -> dict:
    """
    UPSERT product: accumulate stock on conflict
    """
    stmt = (
        insert(Product)
        .values(**product_data)
        .on_conflict_do_update(
            index_elements=["sku"],
            set_={
                # Accumulate stock: original stock + new stock
                "stock": Product.stock + insert(Product).excluded.stock,
                # Update other fields
                "name": insert(Product).excluded.name,
                "price": insert(Product).excluded.price,
            }
        )
        .returning(Product)
    )
    
    result = await session.execute(stmt)
    return result.mappings().first()
```

### User Service

```python
class UserService:
    """User service (supports UPSERT)"""
    
    def __init__(self, session: AsyncSession):
        self.session = session
    
    async def create_or_update(self, email: str, name: str, age: int | None = None) -> dict:
        """Create or update user"""
        stmt = (
            insert(User)
            .values(
                email=email,
                name=name,
                age=age,
                created_at=datetime.utcnow()
            )
            .on_conflict_do_update(
                index_elements=["email"],
                set_={
                    "name": name,
                    "age": age,
                    "updated_at": datetime.utcnow()
                }
            )
            .returning(User)
        )
        
        result = await self.session.execute(stmt)
        user = result.scalar_one()
        
        return {
            "id": user.id,
            "email": user.email,
            "name": user.name,
            "age": user.age
        }
    
    async def bulk_create_or_update(self, users: list[dict]) -> int:
        """Bulk create or update"""
        stmt = (
            insert(User)
            .values(users)
            .on_conflict_do_update(
                index_elements=["email"],
                set_={
                    "name": insert(User).excluded.name,
                    "age": insert(User).excluded.age,
                    "updated_at": datetime.utcnow()
                }
            )
        )
        
        result = await self.session.execute(stmt)
        return result.rowcount
    
    async def create_if_not_exists(self, email: str, name: str) -> bool:
        """Create only if not exists"""
        stmt = (
            insert(User)
            .values(
                email=email,
                name=name,
                created_at=datetime.utcnow()
            )
            .on_conflict_do_nothing(
                index_elements=["email"]
            )
        )
        
        result = await self.session.execute(stmt)
        return result.rowcount > 0  # True = insertion successful, False = already exists
```

## Raw SQL

### Basic Examples

**PostgreSQL**

```python
async def upsert_user_pg(session: AsyncSession, user_data: dict) -> dict | None:
    """
    PostgreSQL native UPSERT
    """
    sql = text("""
        INSERT INTO users (email, name, age, created_at)
        VALUES (:email, :name, :age, :created_at)
        ON CONFLICT (email) DO UPDATE  -- Conflict column
        SET 
            name = EXCLUDED.name,      -- EXCLUDED represents the new inserted value
            age = EXCLUDED.age,
            updated_at = NOW()
        RETURNING id, email, name, age
    """)
    
    result = await session.execute(
        sql,
        {
            "email": user_data["email"],
            "name": user_data["name"],
            "age": user_data.get("age"),
            "created_at": datetime.utcnow()
        }
    )
    
    row = result.mappings().first()
    return dict(row) if row else None
```

**SQLite**

```python
async def upsert_user_sqlite(session: AsyncSession, user_data: dict) -> dict | None:
    """
    SQLite native UPSERT (syntax nearly identical to PostgreSQL)
    """
    sql = text("""
        INSERT INTO users (email, name, age, created_at)
        VALUES (:email, :name, :age, :created_at)
        ON CONFLICT(email) DO UPDATE SET  -- Slight syntax difference in SQLite
            name = excluded.name,
            age = excluded.age,
            updated_at = CURRENT_TIMESTAMP
        RETURNING id, email, name, age
    """)
    
    result = await session.execute(
        sql,
        {
            "email": user_data["email"],
            "name": user_data["name"],
            "age": user_data.get("age"),
            "created_at": datetime.utcnow()
        }
    )
    
    row = result.mappings().first()
    return dict(row) if row else None
```

### Ignore on Conflict

```python
async def insert_or_ignore_user(session: AsyncSession, user_data: dict) -> bool:
    """
    Insert user, ignore if conflict occurs
    """
    # PostgreSQL
    sql = text("""
        INSERT INTO users (email, name, age, created_at)
        VALUES (:email, :name, :age, :created_at)
        ON CONFLICT (email) DO NOTHING
    """)
    
    # SQLite (same syntax)
    # sql = text("""
    #     INSERT INTO users (email, name, age, created_at)
    #     VALUES (:email, :name, :age, :created_at)
    #     ON CONFLICT(email) DO NOTHING
    # """)
    
    result = await session.execute(
        sql,
        {
            "email": user_data["email"],
            "name": user_data["name"],
            "age": user_data.get("age"),
            "created_at": datetime.utcnow()
        }
    )
    
    return result.rowcount > 0  # Return whether insertion was successful
```

### Bulk UPSERT

```python
async def bulk_upsert_products(session: AsyncSession, products: list[dict]) -> int:
    """
    Bulk UPSERT products (raw SQL)
    """
    # PostgreSQL
    sql = text("""
        INSERT INTO products (sku, name, stock, price, created_at)
        VALUES (
            :sku, :name, :stock, :price, :created_at
        )
        ON CONFLICT (sku) DO UPDATE SET
            name = EXCLUDED.name,
            stock = products.stock + EXCLUDED.stock,  -- Accumulate inventory
            price = EXCLUDED.price,
            updated_at = NOW()
    """)
    
    # Execute in bulk
    for product in products:
        await session.execute(
            sql,
            {
                "sku": product["sku"],
                "name": product["name"],
                "stock": product.get("stock", 0),
                "price": product.get("price", 0),
                "created_at": datetime.utcnow()
            }
        )
    
    return len(products)
```

### Partial Updates with Conditional Logic

```python
async def upsert_user_smart(session: AsyncSession, user_data: dict) -> dict | None:
    """
    Smart UPSERT:
    - Update age only if provided
    - Update name only if provided
    - Always update updated_at
    """
    sql = text("""
        INSERT INTO users (email, name, age, created_at)
        VALUES (:email, :name, :age, :created_at)
        ON CONFLICT (email) DO UPDATE SET
            name = COALESCE(:name, users.name),  -- Keep original if new value is NULL
            age = COALESCE(:age, users.age),
            updated_at = NOW()
        RETURNING id, email, name, age, updated_at
    """)
    
    result = await session.execute(
        sql,
        {
            "email": user_data["email"],
            "name": user_data.get("name"),  # May be None
            "age": user_data.get("age"),    # May be None
            "created_at": datetime.utcnow()
        }
    )
    
    row = result.mappings().first()
    return dict(row) if row else None
```

### User Registration/Login: Update Last Login Time if Exists

```python
async def register_or_login(session: AsyncSession, email: str, name: str) -> dict:
    """
    User registration or login:
    - New user: insert
    - Existing user: update last login time
    """
    sql = text("""
        INSERT INTO users (email, name, last_login, created_at)
        VALUES (:email, :name, :now, :now)
        ON CONFLICT (email) DO UPDATE SET
            last_login = EXCLUDED.last_login,
            name = EXCLUDED.name  -- Optional: update username
        RETURNING id, email, name, last_login, created_at
    """)
    
    now = datetime.utcnow()
    result = await session.execute(
        sql,
        {"email": email, "name": name, "now": now}
    )
    
    return dict(result.mappings().first())
```

### Inventory Accumulation

```python
async def add_product_stock(session: AsyncSession, sku: str, quantity: int) -> bool:
    """
    Add product inventory:
    - Product doesn't exist: insert
    - Product exists: accumulate inventory
    """
    sql = text("""
        INSERT INTO products (sku, stock, created_at)
        VALUES (:sku, :quantity, :now)
        ON CONFLICT (sku) DO UPDATE SET
            stock = products.stock + EXCLUDED.stock,
            updated_at = NOW()
    """)
    
    result = await session.execute(
        sql,
        {
            "sku": sku,
            "quantity": quantity,
            "now": datetime.utcnow()
        }
    )
    
    return result.rowcount > 0
```

### User Points Accumulation

```python
async def add_user_points(session: AsyncSession, user_id: int, points: int) -> dict | None:
    """
    Add user points (accumulate)
    """
    sql = text("""
        INSERT INTO user_points (user_id, points, created_at)
        VALUES (:user_id, :points, :now)
        ON CONFLICT (user_id) DO UPDATE SET
            points = user_points.points + EXCLUDED.points,
            updated_at = NOW()
        RETURNING user_id, points
    """)
    
    result = await session.execute(
        sql,
        {
            "user_id": user_id,
            "points": points,
            "now": datetime.utcnow()
        }
    )
    
    row = result.mappings().first()
    return dict(row) if row else None
```

### Tag Counting

Increment by 1 if exists, create with count=1 if not:

```python
async def increment_tag_count(session: AsyncSession, tag_name: str) -> int:
    """
    Tag counting:
    - Tag doesn't exist: insert with count=1
    - Tag exists: count += 1
    """
    sql = text("""
        INSERT INTO tags (name, count, created_at)
        VALUES (:name, 1, :now)
        ON CONFLICT (name) DO UPDATE SET
            count = tags.count + 1,
            updated_at = NOW()
        RETURNING count
    """)
    
    result = await session.execute(
        sql,
        {"name": tag_name, "now": datetime.utcnow()}
    )
    
    return result.scalar() or 0
```