FROM python:3.12-slim
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends ffmpeg && rm -rf /var/lib/apt/lists/*
COPY pyproject.toml worker.py adapters.py media_pipeline.py sandbox.py editor_adapter.py ./
COPY requirements.lock ./
RUN pip install --no-cache-dir --require-hashes -r requirements.lock && pip install --no-cache-dir --no-deps .
RUN useradd --create-home --uid 10001 ruxi
USER ruxi
EXPOSE 8000
CMD ["uvicorn","worker:app","--host","0.0.0.0","--port","8000"]
