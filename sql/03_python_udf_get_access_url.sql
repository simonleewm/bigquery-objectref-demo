-- =============================================================================
-- STEP 3: Zero-Token Image Resolution Gate with OBJ.GET_ACCESS_URL & Python UDF
-- =============================================================================
-- Not every image check requires spending Vertex AI Gemini tokens!
--
-- `OBJ.GET_ACCESS_URL(object_ref, 'r')` generates a short-lived, pre-signed URL
-- governed by the ObjectRef's authorizer connection. We pass that JSON into a
-- BigQuery Managed Python UDF running `Pillow` to check pixel dimensions
-- (`width`, `height`), format, and whether the image meets our 500x500 px
-- marketplace minimum—catching `SKU-1004` (80x80 px) at $0 LLM token cost!
-- =============================================================================

CREATE OR REPLACE FUNCTION `${GCP_PROJECT_ID}.${BQ_DATASET}.inspect_image_dimensions`(
  access_url_json STRING
)
RETURNS STRUCT<
  width INT64,
  height INT64,
  image_format STRING,
  color_mode STRING,
  is_high_res BOOL
>
LANGUAGE python
WITH CONNECTION `${GCP_PROJECT_ID}.${GCP_LOCATION}.${BQ_CONNECTION_ID}`
OPTIONS (
  entry_point = 'inspect_image_dimensions',
  runtime_version = 'python-3.11',
  packages = ['pillow']
)
AS r'''
import io
import json
import urllib.request
from PIL import Image

def inspect_image_dimensions(access_url_json: str):
    if not access_url_json:
        return None
    payload = json.loads(access_url_json)
    read_url = payload.get("access_urls", {}).get("read_url")
    if not read_url:
        return None

    with urllib.request.urlopen(read_url, timeout=15) as resp:
        img_bytes = resp.read()

    with Image.open(io.BytesIO(img_bytes)) as img:
        w, h = img.size
        return {
            "width": int(w),
            "height": int(h),
            "image_format": str(img.format or "UNKNOWN"),
            "color_mode": str(img.mode or "UNKNOWN"),
            "is_high_res": bool(w >= 500 and h >= 500),
        }
''';

-- Persist the technical inspection results so Step 4 has the resolution check columns
CREATE OR REPLACE TABLE `${GCP_PROJECT_ID}.${BQ_DATASET}.product_listings_tech_checked` AS
SELECT
  m.*,
  `${GCP_PROJECT_ID}.${BQ_DATASET}.inspect_image_dimensions`(
    TO_JSON_STRING(OBJ.GET_ACCESS_URL(m.primary_image_ref, 'r'))
  ) AS image_tech_check
FROM
  `${GCP_PROJECT_ID}.${BQ_DATASET}.product_listings_multimodal` AS m;

-- Inspect the resolution check results (notice SKU-1004 is flagged as 80x80 / is_high_res = FALSE)
SELECT
  sku_id,
  listed_title,
  image_tech_check.width AS width_px,
  image_tech_check.height AS height_px,
  image_tech_check.image_format,
  image_tech_check.is_high_res
FROM
  `${GCP_PROJECT_ID}.${BQ_DATASET}.product_listings_tech_checked`
ORDER BY
  sku_id;
