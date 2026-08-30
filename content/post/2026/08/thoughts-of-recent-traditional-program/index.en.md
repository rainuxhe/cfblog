+++
date = '2026-08-30T23:26:08+08:00'
draft = false
title = 'Reflections on Traditional Programming'
description = 'Some reflections on recent old-school programming'
summary = 'Rewriting an AI-generated service by hand — and why know-why and taste still matter'
isCJKLanguage = false
categories = ['life']
tags = ['thought', 'ai', 'AI-Translated']
keywords = ["thought", "ai"]
slug = 'thoughts-on-traditional-programming'
+++

Recently I wrote a backend service the old-school way. Its job is simple: periodically pull data from a source, process it, store it in its own database, and expose a set of APIs for a Grafana dashboard to display.

A few months before this, I'd written a version with AI, using Claude Opus — then the strongest model for coding. I remember it took me just half a day, and most of that went into aligning requirements and tweaking the dashboard; only about ten minutes were spent actually writing code. I never even looked at how the code was implemented — the dashboard rendered fine, and after deploying it, a quick glance showed nothing wrong, so I moved on.

Sometime later, colleagues looking at the dashboard found some issues — data that wasn't cleaned up properly, types that needed adding. They seemed minor, so I dug out the code to fix them myself. But once I started reading, I found plenty of code that rubbed me the wrong way. I went back to the design doc I'd saved back then… hmm, the design was perfectly fine. How on earth did the code end up such a mess?

The high-level design was fine — the feature is simple and it's just an internal service, so there isn't much to design. The individual functions and methods were fine too, and even used plenty of modern idioms I didn't know. What got on my nerves was everything in between: the chain from design down to methods, the project structure, the modularity — all extremely amateurish, exactly like me when I was just learning to code, slapping things together as long as it worked.

The concurrency handling annoyed me the most. The design clearly called for concurrent processing, and the code did use concurrency — but after reading it several times, I realized the AI had thrown in a pile of locks for thread safety and to work around server rate limits, turning it into effectively serial processing. No wonder there was at least a ten-minute delay between reading the data and writing it to the database. And I'd been blaming it on too much source data and slow SQLite writes.

I tried patching the code but couldn't get it to run, and I didn't want to ask the AI to polish a turd either. So I just decided to rewrite it from scratch myself.

Funny enough, this was my first time writing a complete Web API service in Go. Before, I'd either written middleware or CLI tools in Go, taken over someone else's web service, or built web services from scratch in Python. It wasn't hard — it just took some time to set up the project structure. And I didn't follow the AI's design doc either; I came up with my own design.

Throughout this old-school session, I only asked the AI to generate the Go structs for the JSON, review my code, and help me debug. I used to rely on ORMs, but this time I switched to plain SQL to work with the database, which was a nice refresher. I learned Go back in the 1.12 version, so my notes were all outdated — Go 1.27 has been released by now. Go guarantees backward compatibility, but the newer idioms are just more convenient. So as I wrote with the new version, I updated my notes along the way and had the AI fill in the gaps. This simple backend took me quite a while, but I learned a lot and got my knowledge base properly reorganized.

In the traditional-programming era, getting the feature working was usually enough — few developers reviewed code line by line; shipping early and going home was the priority. In the AI-programming era, though, the speed of writing code is unprecedented. As AI grows more capable, it can implement an entire feature in the time it used to take someone to write two functions by hand. And at that point, what matters more than just writing code is knowing why and having taste. After all, "can do" and "can do it well" are two very different things — one word apart, but usually meaning a different architecture or a large-scale refactor. You might say that's unnecessary — with a good `AGENTS.md` and skills, AI can write beautiful code too. But without know-why and taste yourself, how would you even know whether the code is good?

As AI keeps getting more powerful, maybe people won't need know-why or taste to program anymore — they'll just have AI write all the code. Maybe we won't need many dedicated developers in the future. Maybe I'll lose my job next year. Maybe I'll lose interest in programming altogether. But at least for now, when I build something with my own hands, I'm genuinely happy.
