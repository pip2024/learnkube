import os
import socket

from flask import Flask

app = Flask(__name__)

APP_VERSION = os.environ.get("APP_VERSION", "v1")


@app.route("/")
def hello():
    return f"Hello Kubernetes {APP_VERSION} from pod {socket.gethostname()}\n"


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", 8080)))
