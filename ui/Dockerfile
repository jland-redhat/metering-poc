FROM python:3.12-alpine

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .
COPY templates/ templates/
COPY static/ static/

RUN adduser -D -u 1001 appuser
USER 1001

EXPOSE 8080
CMD ["python", "app.py"]
