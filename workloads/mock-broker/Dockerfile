FROM python:3.12-slim
WORKDIR /app
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY mock_broker ./mock_broker
USER 10001
EXPOSE 8000
CMD ["python", "-m", "mock_broker"]
