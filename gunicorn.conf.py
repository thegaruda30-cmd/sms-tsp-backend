# Gunicorn configuration file for production load scaling
import multiprocessing

# Concurrency & Worker tuning
workers = multiprocessing.cpu_count() * 2 + 1
worker_class = 'gthread'
threads = 4

# Network connection settings
keepalive = 10
backlog = 2048

# Prevent memory leaks under high volumes of concurrent requests
max_requests = 2000
max_requests_jitter = 100
