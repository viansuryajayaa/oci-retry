#!/bin/bash
# Auto-retry pembuatan instance Always Free A1 (dipanggil oleh GitHub Actions).
# Berhenti kalau: instance berhasil dibuat, instance "feian" sudah ada, waktu habis, atau error lain.

REGION="ap-batam-1"
NAME="feian"
OCPU=2                       # ganti ke 1 kalau mau peluang lebih besar
MEM=12                       # ganti ke 6 kalau OCPU=1
SUBNET_NAME="public subnet-feian"
WAIT_CAPACITY=60
WAIT_THROTTLE=180
MAX_MINUTES=340              # GitHub membatasi 1 job maksimal 6 jam

PUBKEY='ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCmF5FUZDmI5uUBkJ1/7ZFuOKtlWHOAU/dCU15dEK4Pm5pgw8vJmQPD4OV7OqMolzLnab2EslNAsUzQEmTqeCjFkgyGruON7pdsXA9uiJ6j2dBPwCx2wHEbQRqvmAKCofe8Djg1IorV7GVok63HQjv81KSfSwXQ00g9l57RTAY+JfHHdEDEf+du7FVzxI2lEWlgiV3FKXlaqQyzOOCcHyfxLD6EtZ8uPWQXOyb7cAIvBNBw+6keBUUEKWDKQ3Fjdk/S8U/Qf6pfDabqtHmslmXhfl5qA3KrUPkY8KMV89w76SbaU10xzDfCqTJhwDayaQ3Ir4KGBUq7qrn/JLg8GtT3 ssh-key-2026-11-07'
echo "$PUBKEY" > /tmp/feian.pub

COMP=$(grep -E '^\s*tenancy\s*=' ~/.oci/config | head -1 | cut -d= -f2 | tr -d ' ')
[ -z "$COMP" ] && { echo "Tenancy tidak ketemu di config"; exit 1; }

# Sudah ada instance feian yang hidup? Kalau ya, tidak usah apa-apa.
EXIST=$(oci compute instance list --region "$REGION" --compartment-id "$COMP" --all \
  --query "data[?\"display-name\"=='$NAME' && \"lifecycle-state\"!='TERMINATED' && \"lifecycle-state\"!='TERMINATING'].id | [0]" \
  --raw-output 2>/dev/null)
if [ -n "$EXIST" ] && [ "$EXIST" != "null" ]; then
  echo "Instance '$NAME' sudah ada ($EXIST). Selesai. Matikan workflow ini di tab Actions."
  exit 0
fi

AD=$(oci iam availability-domain list --region "$REGION" --compartment-id "$COMP" --query 'data[0].name' --raw-output)
SUBNET=$(oci network subnet list --region "$REGION" --compartment-id "$COMP" --all \
  --query "data[?\"display-name\"=='$SUBNET_NAME'].id | [0]" --raw-output)
IMAGE=$(oci compute image list --region "$REGION" --compartment-id "$COMP" \
  --operating-system "Canonical Ubuntu" --operating-system-version "24.04" \
  --shape VM.Standard.A1.Flex --sort-by TIMECREATED --sort-order DESC --all \
  --query "data[?!contains(\"display-name\", 'Minimal')].id | [0]" --raw-output)
echo "AD=$AD"; echo "SUBNET=$SUBNET"; echo "IMAGE=$IMAGE"
for v in "$AD" "$SUBNET" "$IMAGE"; do
  if [ -z "$v" ] || [ "$v" = "null" ]; then echo "Ada info kosong, berhenti."; exit 1; fi
done

START=$(date +%s); n=0
while true; do
  n=$((n+1))
  if [ $(( ($(date +%s) - START) / 60 )) -ge $MAX_MINUTES ]; then
    echo "Waktu job habis, lanjut di jadwal berikutnya."; exit 0
  fi
  echo "[$(date -u '+%H:%M:%S') UTC] Percobaan #$n ($OCPU OCPU / $MEM GB)"
  OUT=$(oci compute instance launch --region "$REGION" \
    --compartment-id "$COMP" --availability-domain "$AD" \
    --display-name "$NAME" --shape VM.Standard.A1.Flex \
    --shape-config "{\"ocpus\": $OCPU, \"memoryInGBs\": $MEM}" \
    --image-id "$IMAGE" --subnet-id "$SUBNET" --assign-public-ip true \
    --ssh-authorized-keys-file /tmp/feian.pub 2>&1)

  if echo "$OUT" | grep -q '"lifecycle-state"'; then
    echo "=== BERHASIL! Instance '$NAME' sedang dibuat. ==="
    exit 0
  elif echo "$OUT" | grep -qi 'capacity'; then
    sleep "$WAIT_CAPACITY"
  elif echo "$OUT" | grep -qi 'TooManyRequests\|Too many requests'; then
    sleep "$WAIT_THROTTLE"
  else
    echo "Error lain:"; echo "$OUT" | head -20
    exit 1
  fi
done
