# The parser as a container, for Cloud Run or any host that runs one.
# Standard library only, so nothing to install. No Tesseract: the phone sends
# the text Vision read off a photo, and a small image wakes faster.
FROM python:3.13-slim

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app
COPY . .
RUN useradd --system parser
USER parser

# Cloud Run sets PORT; HOST must be all interfaces inside a container.
ENV HOST=0.0.0.0 PORT=8080
CMD ["python3", "server.py"]
