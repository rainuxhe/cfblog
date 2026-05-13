+++
date = '2026-02-14T12:40:31+08:00'
draft = false
title = 'Flask - Common Application Deployment Solutions'
description = "This article introduces several common deployment solutions for Flask applications in production environments"
isCJKLanguage = false
categories = ["program"]
tags = ["python", "flask", "docker"]
keywords = [
    "python",
    "flask",
    "docker",
]
slug = "flask-common-deploy-methods"
+++

## Introduction

During development and debugging, Flask applications are typically run directly using `app.run()`. However, the built-in WSGI server in Flask is not known for high performance. For production environments, `gunicorn` is commonly used. For legacy projects that don't require high performance and rely heavily on in-process shared variables, using gunicorn might affect inter-request communication, so you may consider using `gevent` directly.

Before Docker became popular, Flask applications in production were typically deployed using virtualenv + gunicorn + supervisor. After Docker gained widespread adoption, the deployment approach shifted to gunicorn + Docker. Without container orchestration services, a reverse proxy like nginx is typically placed in front of the backend services. When using Kubernetes, services are typically exposed via Service + Ingress (or Istio, etc.).

## Running Methods

### Flask Built-in WSGI Server

This is the typical way to run Flask during development.

```python
# main.py
from flask import Flask
from time import sleep

app = Flask(__name__)

@app.get("/test")
def get_test():
    sleep(0.1)
    return "ok"

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=10000)
```

Run it with:

```bash
python main.py
```

### gevent

To run Flask with gevent, you need to install gevent first:

```bash
python -m pip install -U gevent
```

The code requires slight modifications.

Note that `monkey.patch_all()` must be placed at the very beginning of the entry file for the monkey patch to take effect.

```python
# main.py
from gevent import monkey
monkey.patch_all()
import time

from flask import Flask
from gevent.pywsgi import WSGIServer


app = Flask(__name__)


@app.get("/test")
def get_test():
    time.sleep(0.1)
    return "ok"


if __name__ == "__main__":
    server = WSGIServer(("0.0.0.0", 10000), app)
    server.serve_forever()
```

Run it with:

```bash
python main.py
```

### gunicorn + gevent

> If an existing project heavily relies on in-process memory-based shared variables, abruptly switching to gunicorn's multi-worker mode may cause data access inconsistency issues.

Dependencies need to be installed first as well.

```bash
python -m pip install -U gunicorn gevent
```

Unlike using gevent alone, this approach doesn't require code modifications—gunicorn automatically injects gevent's monkey patch.

gunicorn allows configuring startup parameters via command line, but I personally prefer configuring them in gunicorn's configuration file. This allows for dynamic configuration and custom log format modifications.

Here's a sample `gunicorn.conf.py` configuration:

```python
# Gunicorn configuration file
from pathlib import Path
from multiprocessing import cpu_count
import gunicorn.glogging
from datetime import datetime

class CustomLogger(gunicorn.glogging.Logger):
    def atoms(self, resp, req, environ, request_time):
        """
        Override atoms method to customize log placeholders
        """
        # Get all default placeholder data
        atoms = super().atoms(resp, req, environ, request_time)
        
        # Customize 't' (timestamp) format
        now = datetime.now().astimezone()
        atoms['t'] = now.isoformat(timespec="seconds")
        
        return atoms
    

# Preload application code
preload_app = True

# Number of worker processes: typically 2 * CPU cores + 1
# workers = int(cpu_count() * 2 + 1)
workers = 4

# Use gevent async worker class, suitable for I/O-bound applications
# Note: gevent workers don't use the threads parameter; they use coroutines for concurrency
worker_class = "gevent"

# Maximum concurrent connections per gevent worker
worker_connections = 2000

# Bind address and port
bind = "127.0.0.1:10001"

# Process name
proc_name = "flask-dev"

# PID file path
pidfile = str(Path(__file__).parent / "tmp" / "gunicorn.pid")

logger_class = CustomLogger
access_log_format = (
    '{"@timestamp": "%(t)s", '
    '"remote_addr": "%(h)s", '
    '"protocol": "%(H)s", '
    '"host": "%({host}i)s", '
    '"request_method": "%(m)s", '
    '"request_path": "%(U)s", '
    '"status_code": %(s)s, '
    '"response_length": %(b)s, '
    '"referer": "%(f)s", '
    '"user_agent": "%(a)s", '
    '"x_tracking_id": "%({x-tracking-id}i)s", '
    '"request_time": %(L)s}'
)

# Access log path
accesslog = str(Path(__file__).parent / "logs" / "access.log")

# Error log path
errorlog = str(Path(__file__).parent / "logs" / "error.log")

# Log level
loglevel = "debug"
```

Run it with: gunicorn's default config file is `gunicorn.conf.py`. If you use a different filename, specify it with the `-c` parameter.

```bash
gunicorn main:app Process Management: Auto
```

## Traditional-Restart

In traditional server deployments, common process supervision methods include:

1. Configure crontab + shell scripts. Check periodically if the process is running, and restart if not.
2. Configure supervisor.
3. Configure systemd.

Since `supervisor` requires separate installation, and following the principle of using built-in tools when available and minimizing dependencies, I personally don't use supervisor, so this article won't cover how to use supervisor.

When deploying to servers, it's also common to create a separate Python virtual environment for the project.

```bash
# Use Python's built-in venv to create a virtual environment in the current directory
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r ./requirements.txt

# If using uv, simply run uv sync
```

### crontab + shell Scripts (Not Recommended for Production)

When I was new to the field and not familiar with systemd, I often used crontab + shell scripts for process supervision. Looking back, this approach isn't ideal—it requires a high level of shell scripting skills and consideration for various edge cases.

- First, ensure user-level crontab is enabled. Some production environments disable user-level crontab and don't allow configuring system-level crontab.
- crontab operates at minute-level granularity, meaning there could be up to a minute of downtime before detection.
- If there are console logs, you need to manually handle log redirection and log rotation.
- If ulimit is low, you need to manage ulimit settings.
- Zombie processes often appear, requiring extensive status-checking logic in the shell script.

For simple use cases, here's an example:

```bash
#!/bin/bash

# Environment configuration
export FLASK_ENV="production"
export DATABASE_URL="postgresql://user:pass@localhost:5432/mydb"
export REDIS_URL="redis://localhost:6379/0"

script_dir=$(cd $(dirname $0) && pwd)
app_name="gunicorn"  # The actual process name is gunicorn, not Flask app
wsgi_module="wsgi:app"  # Replace with your WSGI entry
socket_path="${script_dir}/myapp.sock"  # Unix Socket path (avoid /run which resets on reboot)
log_file="${script_dir}/app.log"
pid_file="${script_dir}/gunicorn.pid"   # Use PID file for control

# Process detection
is_running() {
    if [ -f "$pid_file" ]; then
        pid=$(cat "$pid_file")
        if ps -p "$pid" > /dev/null 2>&1 && grep -q "gunicorn.*${wsgi_module}" /proc/"$pid"/cmdline 2>/dev/null; then
            echo "Gunicorn (PID: $pid) is running"
            return 0
        else
            rm -f "$pid_file"  # Clean up stale PID
            echo "Stale PID file found, cleaned up"
            return 1
        fi
    else
        # Fallback detection: via socket file + process name
        if [ -S "$socket_path" ] && pgrep -f "gunicorn.*${wsgi_module}" > /dev/null 2>&1; then
            echo "Gunicorn is running (detected by socket)"
            return 0
        fi
        echo "Gunicorn is not running"
        return 1
    fi
}

# Start the application
start_app() {
    is_running
    if [ $? -eq 0 ]; then
        echo "Already running, skip start"
        return 0
    fi

    echo "Starting Gunicorn at $(date)"
    echo "Socket: $socket_path"
    echo "Log: $log_file"

    # Ensure socket directory exists
    mkdir -p "$(dirname "$socket_path")"

    # Start command (key: don't use --daemon, use nohup instead)
    cd "$script_dir" || exit 1
    # Generate PID file
    nohup "$script_dir/venv/bin/gunicorn" \
        --workers 3 \
        --bind "unix:$socket_path" \
        --pid "$pid_file" \
        --access-logfile "$log_file" \
        --error-logfile "$log_file" \
        --log-level info \
        "$wsgi_module" > /dev/null 2>&1 &

    # Wait for startup
    sleep 2
    if is_running; then
        echo "✓ Start success (PID: $(cat "$pid_file" 2>/dev/null))"
        return 0
    else
        echo "✗ Start failed, check $log_file"
        return 1
    fi
}

# Stop the application
stop_app() {
    is_running
    if [ $? -eq 1 ]; then
        echo "Not running, skip stop"
        return 0
    fi

    pid=$(cat "$pid_file" 2>/dev/null)
    echo "Stopping Gunicorn (PID: $pid) gracefully..."

    # Send SIGTERM first (graceful stop)
    kill -15 "$pid" 2>/dev/null || true
    sleep 5

    # Check if still running
    if ps -p "$pid" > /dev/null 2>&1; then
        echo "Still running after 5s, force killing..."
        kill -9 "$pid" 2>/dev/null || true
        sleep 2
    fi

    # Clean up
    rm -f "$pid_file" "$socket_path"
    echo "✓ Stopped"
}

# Restart the application
restart_app() {
    echo "Restarting Gunicorn..."
    stop_app
    sleep 1
    start_app
}

# Entry point
main() {
    # Check if Gunicorn exists
    if [ ! -f "$script_dir/venv/bin/gunicorn" ]; then
        echo "ERROR: Gunicorn not found at $script_dir/venv/bin/gunicorn"
        echo "Hint: Did you activate virtualenv? (source venv/bin/activate)"
        exit 1
    fi

    local action=${1:-start}  # Default action: start

    case "$action" in
        start)
            start_app
            ;;
        stop)
            stop_app
            ;;
        restart)
            restart_app
            ;;
        status)
            is_running
            ;;
        cron-check)
            # Designed for crontab: check and restart silently, no interfering logs
            if ! is_running > /dev/null 2>&1; then
                echo "[$(date '+%F %T')] CRON: Gunicorn down, auto-restarting..." >> "$log_file"
                start_app >> "$log_file" 2>&1
            fi
            ;;
        *)
            echo "Usage: $0 {start|stop|restart|status|cron-check}"
            echo "  cron-check: Silent mode for crontab (logs to app.log only)"
            exit 1
            ;;
    esac
}

main "$@"
```

Test it manually:

```bash
bash app_ctl.sh start
```

Configure crontab:

```
# Edit current user's crontab
crontab -e

# Add the following line (check every minute)
* * * * * /opt/myflaskapp/app_ctl.sh cron-check >/dev/null 2>&1
```

Configure logrotate:

```
# /etc/logrotate.d/myflaskapp
/opt/myflaskapp/app.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    copytruncate  # Avoid Gunicorn losing file handles
}
```

### systemd (Recommended for Production)

1. Create a systemd service file:

```bash
sudo vim /etc/systemd/system/myflaskapp.service
```

2. Example configuration:

```ini
[Unit]
Description=Gunicorn instance for Flask App
After=network.target

[Service]
User=www-data
Group=www-data
WorkingDirectory=/path/to/your/app
Environment="PATH=/path/to/venv/bin"
ExecStart=/path/to/venv/bin/gunicorn \
          --workers 4 \
          --bind unix:/run/myapp.sock \
          --access-logfile - \
          --error-logfile - \
          wsgi:app

# Do NOT add --daemon! systemd needs to monitor the main process directly
Restart=on-failure        # Restart only on abnormal exit (non-zero exit code, killed by signal, etc.)
RestartSec=5s             # Wait 5 seconds before restarting
StartLimitInterval=60s   # Within 60 seconds
StartLimitBurst=5        # Maximum 5 restarts to prevent cascading failures
TimeoutStopSec=30        # Wait 30 seconds for graceful shutdown

# Security hardening
PrivateTmp=true
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=/run /var/log/myapp

[Install]
WantedBy=multi-user.target
```

3. Enable and start the service:

```bash
sudo systemctl daemon-reload
sudo systemctl enable myflaskapp    # Enable at boot
sudo systemctl start myflaskapp
```

Try stopping the backend service process with `kill -9` to see if it gets restarted.

> Note: `kill -15` is considered a normal stop, not an abnormal exit.

## Docker Deployment

1. Dockerfile. Python projects typically don't require multi-stage builds; a single stage is sufficient.

```dockerfile
FROM python:3.11-slim-bookworm

# Security hardening
## Create non-root user (avoid using nobody as it has overly restrictive permissions)
RUN useradd -m -u 1000 appuser && \
    # Install runtime-required system libraries (not build tools)
    apt-get update && apt-get install -y --no-install-recommends \
        libgomp1 \
        libpq5 \
        libsqlite3-0 \
        && rm -rf /var/lib/apt/lists/* \
        && apt-get autoremove -y \
        && apt-get clean

# Python optimization
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /app

# Leverage Docker layer caching: copy requirements first
COPY requirements.txt .
RUN pip install --no-cache-dir --prefer-binary -r requirements.txt \
    && rm -rf /root/.cache

# Application code
COPY --chown=appuser:appuser . .

# Run as non-root user
USER appuser

# Startup
EXPOSE 8000
CMD ["gunicorn", "--config", "config/gunicorn.conf.py", "wsgi:app"]
```

2. Create docker-compose.yaml:

```yaml
services:
  web:
    image: myflaskapp:latest
    container_name: flask_web
    # Port mapping
    ## If nginx is also deployed in Docker with the same network configuration, port mapping may be omitted
    ports:
      - "8000:8000"
    # Environment variables
    environment:
      - FLASK_ENV=production
      - DATABASE_URL=postgresql://user:pass@db:5432/mydb
      - REDIS_URL=redis://redis:6379/0
    # Health check
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8000/health"]
      interval: 30s      # Check every 30 seconds
      timeout: 5s        # Timeout after 5 seconds
      start_period: 15s  # Start health checks 15 seconds after container starts (give app time to initialize)
      retries: 3         # Mark as unhealthy after 3 failed retries
    
    # Auto-restart policy
    restart: unless-stopped  # always / on-failure / unless-stopped
    
    # Resource limits
    deploy:
      resources:
        limits:
          cpus: '2'        # Max 2 CPUs
          memory: 1G       # Max 1GB memory
        reservations:
          cpus: '0.5'      # Reserve 0.5 CPUs
          memory: 256M     # Reserve 256MB memory
    
    # ulimit settings (prevent resource abuse)
    ulimits:
      nproc: 65535       # Max number of processes
      nofile:
        soft: 65535      # Soft limit for open files
        hard: 65535      # Hard limit for open files
      core: 0            # Disable core dump
    
    # Security hardening
    security_opt:
      - no-new-privileges:true  # Prevent privilege escalation
    
    # Read-only filesystem (except /tmp)
    read_only: true
    tmpfs:
      - /tmp:rw,noexec,nosuid,size=100m
    
    # Volume mounts (logs, temporary files)
    volumes:
      - ./logs:/app/logs:rw
      # - ./static:/app/static:ro  # Static files (optional)
    
    # Network
    networks:
      - app-network
        
# Network configuration
networks:
  app-network:
    driver: bridge

# Volume configuration
volumes:
  db_data:
    driver: local
  redis_data:
    driver: local
```

## Kubernetes Deployment

### Deployment

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: flask-app
  namespace: default
  labels:
    app: flask-app
    tier: backend
spec:
  replicas: 3
  selector:
    matchLabels:
      app: flask-app
  template:
    metadata:
      labels:
        app: flask-app
        tier: backend
    spec:
      securityContext:
        runAsNonRoot: true      # Disallow running as root
        runAsUser: 1000         # Use non-root user
        runAsGroup: 1000
        fsGroup: 1000
        seccompProfile:
          type: RuntimeDefault  # Enable seccomp security policy
      containers:
      - name: flask-app
        image: myregistry.com/myflaskapp:1.0.0
        imagePullPolicy: IfNotPresent  # Use Always in production
        ports:
        - name: http
          containerPort: 8000
          protocol: TCP
        env:
        - name: FLASK_ENV
          value: "production"
        - name: DATABASE_URL
          valueFrom:
            secretKeyRef:
              name: flask-app-secrets
              key: database-url
        - name: REDIS_URL
          valueFrom:
            secretKeyRef:
              name: flask-app-secrets
              key: redis-url
        - name: SECRET_KEY
          valueFrom:
            secretKeyRef:
              name: flask-app-secrets
              key: secret-key
        resources:
          requests:
            memory: "256Mi"
            cpu: "100m"
          limits:
            memory: "512Mi"   # OOM Kill if exceeded
            cpu: "500m"
        livenessProbe:
          httpGet:
            path: /health
            port: 8000
            scheme: HTTP
          initialDelaySeconds: 30  # Start checks 30 seconds after start
          periodSeconds: 10        # Check every 10 seconds
          timeoutSeconds: 3        # Timeout after 3 seconds
          successThreshold: 1
          failureThreshold: 3      # Restart container after 3 failures
        readinessProbe:
          httpGet:
            path: /health
            port: 8000
            scheme: HTTP
          initialDelaySeconds: 10  # Start checks 10 seconds after start
          periodSeconds: 5         # Check every 5 seconds
          timeoutSeconds: 2
          successThreshold: 1
          failureThreshold: 3      # Remove from Service after 3 failures
        startupProbe:
          httpGet:
            path: /health
            port: 8000
            scheme: HTTP
          failureThreshold: 30     # Max 30 retries
          periodSeconds: 5         # Every 5 seconds, total 150 seconds tolerance for slow start
          timeoutSeconds: 3
        securityContext:
          allowPrivilegeEscalation: false  # Prevent privilege escalation
          readOnlyRootFilesystem: true     # Read-only root filesystem
          capabilities:
            drop:
            - ALL                          # Drop all Linux capabilities
          privileged: false
        volumeMounts:
        - name: tmp-volume
          mountPath: /tmp
        - name: config-volume
          mountPath: /app/config
          readOnly: true
      imagePullSecrets:
      - name: registry-secret  # If using private registry
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 100
            podAffinityTerm:
              labelSelector:
                matchExpressions:
                - key: app
                  operator: In
                  values:
                  - flask-app
              topologyKey: kubernetes.io/hostname  # Avoid scheduling all Pods on same node
      volumes:
      - name: tmp-volume
        emptyDir:
          medium: Memory  # Use memory volume for faster performance
          sizeLimit: 100Mi
      - name: config-volume
        configMap:
          name: flask-app-config
```

### Service

```yaml
apiVersion: v1
kind: Service
metadata:
  name: flask-app-service
  namespace: default
  labels:
    app: flask-app
    tier: backend
spec:
  type: ClusterIP
  selector:
    app: flask-app
  ports:
  - name: http
    port: 80        # Service port
    targetPort: 8000  # Pod port
    protocol: TCP
```

### Ingress

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: flask-app-ingress
  namespace: default
  annotations:
    # ==================== Nginx Configuration ====================
    kubernetes.io/ingress.class: "nginx"
    
    # Enable HTTPS redirect
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
    
    # Rate limiting (10 requests per second, burst 20)
    nginx.ingress.kubernetes.io/limit-rps: "10"
    nginx.ingress.kubernetes.io/limit-burst-multiplier: "2"
    
    # Client real IP
    nginx.ingress.kubernetes.io/enable-real-ip: "true"
    nginx.ingress.kubernetes.io/proxy-real-ip-cidr: "0.0.0.0/0"
    
    # Connection timeout
    nginx.ingress.kubernetes.io/proxy-connect-timeout: "60"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "60"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "60"
    
    # Buffer size
    nginx.ingress.kubernetes.io/proxy-buffering: "on"
    nginx.ingress.kubernetes.io/proxy-buffer-size: "16k"
    nginx.ingress.kubernetes.io/proxy-buffers-number: "4"
    
    # Gzip compression
    nginx.ingress.kubernetes.io/enable-gzip: "true"
    nginx.ingress.kubernetes.io/gzip-level: "6"
    nginx.ingress.kubernetes.io/gzip-min-length: "1024"
    nginx.ingress.kubernetes.io/gzip-types: "text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript"
    
    # Security headers
    nginx.ingress.kubernetes.io/configuration-snippet: |
      add_header X-Frame-Options "SAMEORIGIN" always;
      add_header X-Content-Type-Options "nosniff" always;
      add_header X-XSS-Protection "1; mode=block" always;
      add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    
    # Authentication
    # nginx.ingress.kubernetes.io/auth-type: basic
    # nginx.ingress.kubernetes.io/auth-secret: flask-app-basic-auth
    # nginx.ingress.kubernetes.io/auth-realm: "Authentication Required"
    
    # Custom error pages
    # nginx.ingress.kubernetes.io/custom-http-errors: "404,500,502,503,504"
    # nginx.ingress.kubernetes.io/default-backend: custom-error-pages
    
    # Rewrite target
    # nginx.ingress.kubernetes.io/rewrite-target: /$1
    
    # WAF (if ModSecurity is installed)
    # nginx.ingress.kubernetes.io/enable-modsecurity: "true"
    # nginx.ingress.kubernetes.io/modsecurity-snippet: |
    #   SecRuleEngine On
    #   SecRequestBodyAccess On

spec:
  tls:
  - hosts:
    - flask.example.com
    secretName: flask-app-tls-secret  # TLS certificate Secret

  rules:
  - host: flask.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: flask-app-service
            port:
              number: 80
```
