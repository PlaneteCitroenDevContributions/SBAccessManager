# syntax=docker/dockerfile:1
FROM fedora:36
WORKDIR /code

# provided for demo / must be adapted
ENV FLASK_APP=app.py
RUN apk add --no-cache gcc musl-dev linux-headers
COPY requirements.txt requirements.txt
RUN pip install -r requirements.txt
COPY . .
CMD ["flask", "run"]