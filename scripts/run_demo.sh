#!/usr/bin/env bash
# ==============================================================================
# BigQuery ObjectRef Multimodal Demo — End-to-End CLI Runner
# Scenario: E-Commerce Marketplace Listing Auditor ("Does the Photo Match the Listing?")
#
# Subcommands:
#   ./scripts/run_demo.sh check          Verify .env, gcloud auth, CSV & sample images
#   ./scripts/run_demo.sh setup          Enable APIs, create bucket, dataset, BQ connection & IAM
#   ./scripts/run_demo.sh upload         Upload sample images to GCS & load staging CSV into BQ
#   ./scripts/run_demo.sh step1          Run Step 1: OBJ.LIST() spontaneous discovery
#   ./scripts/run_demo.sh step2          Run Step 2: OBJ.MAKE_REF() + OBJ.FETCH_METADATA() table
#   ./scripts/run_demo.sh step3          Run Step 3: OBJ.GET_ACCESS_URL() + Python UDF (Pillow)
#   ./scripts/run_demo.sh step4          Run Step 4: Multimodal AI.IF + AI.CLASSIFY + AI.GENERATE + Pipe (|>)
#   ./scripts/run_demo.sh all            Run upload + step1 + step2 + step3 + step4
#   ./scripts/run_demo.sh teardown       Delete demo BQ dataset, connection, and GCS images
#
# Append --dry-run to any command to preview all gcloud/bq/SQL commands without executing.
# ==============================================================================

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${REPO_ROOT}/.env"
LOG_DIR="${REPO_ROOT}/logs"
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/demo_run.log"

DRY_RUN=0
ACTION="${1:-help}"
shift || true
for arg in "$@"; do
  case "$arg" in
    --dry-run|-n) DRY_RUN=1 ;;
    *) echo "Unknown flag: $arg" >&2; exit 1 ;;
  esac
done

# Auto-create .env from .env.example on first run if missing
if [[ ! -f "${ENV_FILE}" && -f "${REPO_ROOT}/.env.example" && "${DRY_RUN}" -eq 0 ]]; then
  cp "${REPO_ROOT}/.env.example" "${ENV_FILE}"
  printf "\033[1;33m==>\033[0m Created .env from .env.example — please fill in the YOUR_* placeholders in .env.\n"
fi

# Load .env if present; fall back to .env.example for --dry-run
if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
elif [[ "${DRY_RUN}" -eq 1 && -f "${REPO_ROOT}/.env.example" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/.env.example"
  set +a
fi

: "${GCLOUD_ACCOUNT:=}"
: "${GCP_PROJECT_ID:=YOUR_GCP_PROJECT_ID}"
: "${GCP_LOCATION:=US}"
: "${GCS_BUCKET_LOCATION:=US}"
: "${GCS_BUCKET_NAME:=${GCP_PROJECT_ID}-bq-objectref-demo}"
: "${GCS_IMAGE_PREFIX:=product_listings/images}"
: "${BQ_DATASET:=bq_objectref_demo}"
: "${BQ_CONNECTION_ID:=bq_objectref_demo_gcs_conn}"
: "${GEMINI_ENDPOINT:=gemini-3.5-flash-lite}"

export GCLOUD_ACCOUNT GCP_PROJECT_ID GCP_LOCATION GCS_BUCKET_LOCATION
export GCS_BUCKET_NAME GCS_IMAGE_PREFIX BQ_DATASET BQ_CONNECTION_ID GEMINI_ENDPOINT

if [[ -n "${GCLOUD_ACCOUNT}" && "${GCLOUD_ACCOUNT}" != "YOUR_GCP_ACCOUNT_EMAIL" && "${GCLOUD_ACCOUNT}" != "your-email@example.com" ]]; then
  export CLOUDSDK_CORE_ACCOUNT="${GCLOUD_ACCOUNT}"
fi

log() {
  printf "\033[1;34m==>\033[0m %s\n" "$*"
  printf "[%s] %s\n" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$*" >> "${LOG_FILE}"
}

run_cmd() {
  printf "    \033[0;36m$\033[0m %s\n" "$*"
  printf "[%s] CMD: %s\n" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$*" >> "${LOG_FILE}"
  if [[ "${DRY_RUN}" -eq 0 ]]; then
    "$@"
  fi
}

render_sql() {
  local sql_file="$1"
  envsubst '${GCP_PROJECT_ID} ${GCP_LOCATION} ${GCS_BUCKET_NAME} ${GCS_IMAGE_PREFIX} ${BQ_DATASET} ${BQ_CONNECTION_ID} ${GEMINI_ENDPOINT}' < "${sql_file}"
}

run_sql_file() {
  local sql_file="$1"
  local label="$2"
  log "${label} (${sql_file##*/})"
  local rendered
  rendered="$(render_sql "${sql_file}")"
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    printf "\033[0;33m--- Rendered SQL (%s) ---\033[0m\n%s\n\033[0;33m-------------------------\033[0m\n" "${sql_file##*/}" "${rendered}"
    return 0
  fi
  echo "${rendered}" | bq --project_id="${GCP_PROJECT_ID}" --location="${GCP_LOCATION}" query --use_legacy_sql=false --format=pretty
}

check_env() {
  log "Checking configuration and demo input files"
  if [[ "${DRY_RUN}" -eq 0 ]]; then
    if [[ "${GCP_PROJECT_ID}" == *"YOUR_"* || "${GCP_PROJECT_ID}" == "your-gcp-project-id" || -z "${GCP_PROJECT_ID}" ]]; then
      echo "ERROR: Please set a real GCP_PROJECT_ID in .env" >&2
      exit 1
    fi
    if [[ "${GCS_BUCKET_NAME}" == *"YOUR_"* || -z "${GCS_BUCKET_NAME}" ]]; then
      echo "ERROR: Please set a real GCS_BUCKET_NAME in .env" >&2
      exit 1
    fi
    if [[ -n "${CLOUDSDK_CORE_ACCOUNT:-}" ]] && command -v gcloud >/dev/null 2>&1; then
      local authed
      authed="$(gcloud auth list --format='value(account)' 2>/dev/null || true)"
      if [[ -n "${authed}" ]] && ! grep -Fxq "${CLOUDSDK_CORE_ACCOUNT}" <<< "${authed}"; then
        echo "ERROR: Account '${CLOUDSDK_CORE_ACCOUNT}' is not authenticated in gcloud. Run: gcloud auth login ${CLOUDSDK_CORE_ACCOUNT}" >&2
        exit 1
      fi
    fi
  fi
  if [[ ! -f "${REPO_ROOT}/data/product_listings.csv" ]]; then
    echo "ERROR: Missing structured CSV input file data/product_listings.csv" >&2
    exit 1
  fi
  local img_count
  img_count="$(find "${REPO_ROOT}/sample_images" \( -name '*.jpg' -o -name '*.png' \) 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "${img_count}" -lt 7 ]]; then
    echo "ERROR: Expected 7 sample images in sample_images/, found ${img_count}." >&2
    exit 1
  fi
  echo "  Account          : ${CLOUDSDK_CORE_ACCOUNT:-<default gcloud account>}"
  echo "  Project ID       : ${GCP_PROJECT_ID}"
  echo "  Location         : ${GCP_LOCATION}"
  echo "  GCS Bucket       : gs://${GCS_BUCKET_NAME}/${GCS_IMAGE_PREFIX}"
  echo "  BigQuery Dataset : ${GCP_PROJECT_ID}:${BQ_DATASET}"
  echo "  BQ Connection    : ${GCP_PROJECT_ID}.${GCP_LOCATION}.${BQ_CONNECTION_ID}"
  echo "  Input CSV        : data/product_listings.csv (6 product rows)"
  echo "  Sample Images    : ${img_count} files ready in sample_images/"
}

do_setup() {
  check_env
  log "1/5 Enabling required Google Cloud APIs on project ${GCP_PROJECT_ID}"
  run_cmd gcloud services enable \
    bigquery.googleapis.com \
    bigqueryconnection.googleapis.com \
    aiplatform.googleapis.com \
    storage.googleapis.com \
    --project="${GCP_PROJECT_ID}"

  log "2/5 Creating Cloud Storage bucket gs://${GCS_BUCKET_NAME} (if not exists)"
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    run_cmd gcloud storage buckets create "gs://${GCS_BUCKET_NAME}" \
      --project="${GCP_PROJECT_ID}" \
      --location="${GCS_BUCKET_LOCATION}" \
      --uniform-bucket-level-access
  else
    if ! gcloud storage buckets describe "gs://${GCS_BUCKET_NAME}" --project="${GCP_PROJECT_ID}" >/dev/null 2>&1; then
      run_cmd gcloud storage buckets create "gs://${GCS_BUCKET_NAME}" \
        --project="${GCP_PROJECT_ID}" \
        --location="${GCS_BUCKET_LOCATION}" \
        --uniform-bucket-level-access
    else
      echo "    Bucket gs://${GCS_BUCKET_NAME} already exists."
    fi
  fi

  log "3/5 Creating BigQuery dataset ${GCP_PROJECT_ID}:${BQ_DATASET} (if not exists)"
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    run_cmd bq --project_id="${GCP_PROJECT_ID}" --location="${GCP_LOCATION}" mk --dataset "${GCP_PROJECT_ID}:${BQ_DATASET}"
  else
    if ! bq --project_id="${GCP_PROJECT_ID}" show --dataset "${GCP_PROJECT_ID}:${BQ_DATASET}" >/dev/null 2>&1; then
      run_cmd bq --project_id="${GCP_PROJECT_ID}" --location="${GCP_LOCATION}" mk --dataset "${GCP_PROJECT_ID}:${BQ_DATASET}"
    else
      echo "    Dataset ${GCP_PROJECT_ID}:${BQ_DATASET} already exists."
    fi
  fi

  log "4/5 Creating BigQuery Cloud Resource Connection ${BQ_CONNECTION_ID}"
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    run_cmd bq mk --connection \
      --connection_type=CLOUD_RESOURCE \
      --project_id="${GCP_PROJECT_ID}" \
      --location="${GCP_LOCATION}" \
      "${BQ_CONNECTION_ID}"
  else
    if ! bq show --connection --project_id="${GCP_PROJECT_ID}" --location="${GCP_LOCATION}" "${BQ_CONNECTION_ID}" >/dev/null 2>&1; then
      run_cmd bq mk --connection \
        --connection_type=CLOUD_RESOURCE \
        --project_id="${GCP_PROJECT_ID}" \
        --location="${GCP_LOCATION}" \
        "${BQ_CONNECTION_ID}"
    else
      echo "    Connection ${BQ_CONNECTION_ID} already exists."
    fi
  fi

  log "5/5 Granting Storage Object Viewer & Vertex AI User to the Connection Service Account"
  local conn_sa="<connection-service-account>"
  if [[ "${DRY_RUN}" -eq 0 ]]; then
    conn_sa="$(bq show --format=json --connection --project_id="${GCP_PROJECT_ID}" --location="${GCP_LOCATION}" "${BQ_CONNECTION_ID}" \
      | python3 -c 'import json,sys; print(json.load(sys.stdin)["cloudResource"]["serviceAccountId"])')"
  fi
  echo "    Connection Service Account: ${conn_sa}"

  run_cmd gcloud storage buckets add-iam-policy-binding "gs://${GCS_BUCKET_NAME}" \
    --member="serviceAccount:${conn_sa}" \
    --role="roles/storage.objectViewer"

  run_cmd gcloud projects add-iam-policy-binding "${GCP_PROJECT_ID}" \
    --member="serviceAccount:${conn_sa}" \
    --role="roles/aiplatform.user" \
    --condition=None >/dev/null

  log "Waiting 15 seconds for IAM propagation..."
  if [[ "${DRY_RUN}" -eq 0 ]]; then
    sleep 15
  fi
}

do_upload() {
  check_env
  log "Uploading 7 sample product images to gs://${GCS_BUCKET_NAME}/${GCS_IMAGE_PREFIX}/"
  run_cmd gcloud storage cp "${REPO_ROOT}/sample_images/"* "gs://${GCS_BUCKET_NAME}/${GCS_IMAGE_PREFIX}/" --project="${GCP_PROJECT_ID}"

  log "Loading structured CSV seed data/product_listings.csv into ${BQ_DATASET}.product_listings_staging"
  run_cmd bq --project_id="${GCP_PROJECT_ID}" --location="${GCP_LOCATION}" load \
    --replace \
    --source_format=CSV \
    --skip_leading_rows=1 \
    --autodetect \
    "${BQ_DATASET}.product_listings_staging" \
    "${REPO_ROOT}/data/product_listings.csv"
}

do_teardown() {
  check_env
  log "Tearing down BigQuery dataset ${GCP_PROJECT_ID}:${BQ_DATASET}"
  run_cmd bq --project_id="${GCP_PROJECT_ID}" rm -r -f --dataset "${GCP_PROJECT_ID}:${BQ_DATASET}" || true

  log "Tearing down BigQuery connection ${BQ_CONNECTION_ID}"
  run_cmd bq rm --connection --force --project_id="${GCP_PROJECT_ID}" --location="${GCP_LOCATION}" "${BQ_CONNECTION_ID}" || true

  log "Deleting sample images in gs://${GCS_BUCKET_NAME}/${GCS_IMAGE_PREFIX}/"
  run_cmd gcloud storage rm -r "gs://${GCS_BUCKET_NAME}/${GCS_IMAGE_PREFIX}" --project="${GCP_PROJECT_ID}" || true
}

case "${ACTION}" in
  check)
    check_env
    ;;
  setup)
    do_setup
    ;;
  upload)
    do_upload
    ;;
  step1|obj-list)
    check_env
    run_sql_file "${REPO_ROOT}/sql/01_spontaneous_discovery_obj_list.sql" "Step 1: Spontaneous Discovery with OBJ.LIST()"
    ;;
  step2|build-table)
    check_env
    run_sql_file "${REPO_ROOT}/sql/02_build_multimodal_table_objectref.sql" "Step 2: Build Native Multimodal Table with ObjectRef & ARRAY<ObjectRef>"
    ;;
  step3|python-udf)
    check_env
    run_sql_file "${REPO_ROOT}/sql/03_python_udf_get_access_url.sql" "Step 3: Zero-Token Image Resolution Check via OBJ.GET_ACCESS_URL() + Python UDF"
    ;;
  step4|ai-audit)
    check_env
    run_sql_file "${REPO_ROOT}/sql/04_multimodal_ai_and_pipe_syntax.sql" "Step 4: Multimodal Listing Audit with AI.IF + AI.CLASSIFY + AI.GENERATE + Pipe (|>)"
    ;;
  all)
    do_upload
    run_sql_file "${REPO_ROOT}/sql/01_spontaneous_discovery_obj_list.sql" "Step 1: Spontaneous Discovery with OBJ.LIST()"
    run_sql_file "${REPO_ROOT}/sql/02_build_multimodal_table_objectref.sql" "Step 2: Build Native Multimodal Table with ObjectRef & ARRAY<ObjectRef>"
    run_sql_file "${REPO_ROOT}/sql/03_python_udf_get_access_url.sql" "Step 3: Zero-Token Image Resolution Check via OBJ.GET_ACCESS_URL() + Python UDF"
    run_sql_file "${REPO_ROOT}/sql/04_multimodal_ai_and_pipe_syntax.sql" "Step 4: Multimodal Listing Audit with AI.IF + AI.CLASSIFY + AI.GENERATE + Pipe (|>)"
    ;;
  teardown|clean-gcp)
    do_teardown
    ;;
  *)
    grep -E '^#   \./scripts/run_demo\.sh' "${BASH_SOURCE[0]}" | sed 's/^# //'
    ;;
esac
