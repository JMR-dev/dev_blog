# Use a custom Dockerfile to include restic and gsutil
FROM python:3.11-slim

# Install restic and curl (to get cloud-sdk)
RUN apt-get update && apt-get install -y restic curl gnupg \
    && echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] http://packages.cloud.google.com/apt cloud-sdk main" | tee -a /etc/apt/sources.list.d/google-cloud-sdk.list \
    && curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key --keyring /usr/share/keyrings/cloud.google.gpg add - \
    && apt-get update && apt-get install -y google-cloud-cli \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

# Cloud Run functions expect a specific entrypoint
ENTRYPOINT ["functions-framework", "--target", "run_backup", "--signature-type", "cloudevent"]
