import os
import socket

from flask import Flask

app = Flask(__name__)

APP_VERSION = os.environ.get("APP_VERSION", "v1")
GREETING_FILE = os.environ.get("GREETING_FILE", "/etc/config/greeting")
LOG_FILE = os.environ.get("LOG_FILE", "/var/log/learnkube/app.log")
COUNTER_FILE = os.environ.get("COUNTER_FILE", "/data/counter.txt")

os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
os.makedirs(os.path.dirname(COUNTER_FILE), exist_ok=True)


def get_greeting():
    try:
        with open(GREETING_FILE) as f:
            return f.read().strip()
    except FileNotFoundError:
        return "Hello"


def log_request():
    with open(LOG_FILE, "a") as f:
        f.write(f"request from {socket.gethostname()}\n")


def next_count():
    try:
        with open(COUNTER_FILE) as f:
            count = int(f.read().strip())
    except (FileNotFoundError, ValueError):
        count = 0
    count += 1
    with open(COUNTER_FILE, "w") as f:
        f.write(str(count))
    return count


@app.route("/")
def hello():
    log_request()
    count = next_count()
    return (
        f"{get_greeting()} Kubernetes {APP_VERSION} from pod {socket.gethostname()} "
        f"(request #{count})\n"
    )


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", 8080)))
