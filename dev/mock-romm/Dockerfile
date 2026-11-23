# Mock RomM API for Sleepoverr's test environment. See ../README.md.
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /srv/mock-romm

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY mock_romm ./mock_romm
COPY fixtures ./fixtures
COPY resolve_igdb_ids.py ./

RUN useradd --system --uid 10001 mockromm && chown -R mockromm /srv/mock-romm
USER mockromm

EXPOSE 8080

HEALTHCHECK --interval=15s --timeout=5s --start-period=10s --retries=3 \
    CMD python -c "import sys, urllib.request; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8080/api/heartbeat', timeout=4).status == 200 else 1)"

CMD ["uvicorn", "--factory", "mock_romm.main:create_app", "--host", "0.0.0.0", "--port", "8080"]
