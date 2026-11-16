# ==============================================================================
# Convenience targets for bigquery-objectref-demo. All targets auto-load ./.env.
#
#   make check             Verify .env placeholders, gcloud account, CSV & sample images
#   make setup             One-time GCP setup (APIs, bucket, dataset, connection, IAM)
#   make upload            Upload sample_images/* to GCS & load product_listings.csv into BQ
#   make step1..step4      Run individual SQL pipeline steps
#   make all               Run upload + step1 + step2 + step3 + step4 end-to-end
#   make dry-run           Print all gcloud/bq commands and rendered SQL offline
#   make teardown          Clean up BQ dataset, connection, and GCS objects
# ==============================================================================

SHELL := bash
.ONESHELL:
.DEFAULT_GOAL := help

REPO_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
RUNNER    := bash $(REPO_ROOT)/scripts/run_demo.sh

ifneq (,$(wildcard $(REPO_ROOT)/.env))
  include $(REPO_ROOT)/.env
  export
endif

.PHONY: help check setup upload step1 step2 step3 step4 all dry-run teardown

help: ## Show available Make targets
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## ' $(firstword $(MAKEFILE_LIST)) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

check: ## Verify .env configuration, product_listings.csv, and sample_images/*
	$(RUNNER) check

setup: ## One-time GCP setup (APIs, GCS bucket, BQ dataset, Cloud Resource Connection & IAM)
	$(RUNNER) setup

upload: ## Upload sample_images/* to GCS and load product_listings.csv into BQ staging
	$(RUNNER) upload

step1: ## Run Step 1 SQL: Spontaneous GCS discovery with OBJ.LIST()
	$(RUNNER) step1

step2: ## Run Step 2 SQL: Build native multimodal table with ObjectRef & ARRAY<ObjectRef>
	$(RUNNER) step2

step3: ## Run Step 3 SQL: Zero-token image resolution gate with OBJ.GET_ACCESS_URL() + Python UDF
	$(RUNNER) step3

step4: ## Run Step 4 SQL: Multimodal listing auditor with AI.IF, AI.CLASSIFY, AI.GENERATE & Pipe (|>)
	$(RUNNER) step4

all: ## Run upload + step1 + step2 + step3 + step4 end-to-end
	$(RUNNER) all

dry-run: ## Print all gcloud/bq commands and rendered SQL without executing
	$(RUNNER) setup --dry-run
	$(RUNNER) all --dry-run

teardown: ## Remove demo BQ dataset, connection, and uploaded GCS objects
	$(RUNNER) teardown
