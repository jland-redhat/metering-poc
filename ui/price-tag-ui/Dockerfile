FROM python:3.12-alpine

RUN pip install --no-cache-dir flask psycopg2-binary

WORKDIR /app
COPY app.py .

USER 1001
EXPOSE 8080
ENTRYPOINT ["python", "app.py"]
