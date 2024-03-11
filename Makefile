SHELL := bash

.DEFAULT_GOAL := @goal
.SHELLFLAGS := -eu -o pipefail -c
.PHONY: build test run
.ONESHELL:
.DELETE_ON_ERROR:

## env
export PATH := ./bin:$(PATH)
export KUBECONFIG ?= $(HOME)/.kube/config
export K8S_HOST := $(shell kubectl config view --minify --output jsonpath="{.clusters[*].cluster.server}")

## recipe
@goal: distclean dist check

distclean:
	: ## $@
	rm -rf dist

clean: distclean
	: ## $@
	rm -rf assets/cluster-keys.json.*
	helmfile destroy ||:
	kubectl delete pvc --all -n vault ||:
	kubectl delete pv --all -n vault ||:
	kubectl delete namespace vault ||:
	kubectl delete namespace eso ||:
	kubectl delete clusterrolebinding role-tokenreview-binding -n default ||:

dist:
	: ## $@
	mkdir -p $@ $@/bin
	cp assets/helm-$(shell uname -s)-$(shell uname -m)-* $@/bin/helm
	cp -rf src policy $@/
	cat manifest/*.yaml \
		| envsubst \
		| tee $@/manifest.yaml

	yq -re <$(KUBECONFIG) \
		'.clusters[0].cluster."certificate-authority-data"' \
	| base64 -d >$@/ca.crt
dist/unseal-keys.txt: dist assets/cluster-keys.json.gpg
	: ## $@
	gpg --verify \
		assets/cluster-keys.json.sign \
		assets/cluster-keys.json.gpg

	<assets/cluster-keys.json.gpg gpg -d \
		| jq -re ".unseal_keys_b64[]" >$@
dist/root-token.txt: dist assets/cluster-keys.json.gpg
	: ## $@
	gpg --verify \
		assets/cluster-keys.json.sign \
		assets/cluster-keys.json.gpg

	<assets/cluster-keys.json.gpg gpg -d \
		| jq -re ".root_token" >$@
dist/auth-sa-token.txt: dist
	: ## $@
	kubectl -n eso get secret auth-sa-token -ojson \
		| jq -re ".data.token" \
		| base64 -d >$@

check:
	: ## $@
	helmfile deps

install: helmfile.lock dist/manifest.yaml
	: ## $@
	helmfile apply
	kubectl apply -f dist/manifest.yaml

vault/init: assets/cluster-keys.json.gpg \
						dist/root-token.txt \
						dist/ca.crt \
						dist/auth-sa-token.txt \
						vault/unseal
vault/init:
	: ## $@
	cd dist
	src/vault.sh vault-0 login "$$(cat root-token.txt)"
	src/vault.sh vault-0 secrets enable -path=secret kv-v2 ||:
	src/vault.sh vault-0 auth enable -path=kubernetes/internal kubernetes ||:
	src/vault.sh vault-0 write auth/kubernetes/internal/config \
		token_reviewer_jwt="$$(cat auth-sa-token.txt)" \
		kubernetes_host="$(K8S_HOST)" \
		kubernetes_ca_cert="$$(cat ca.crt)"
	src/vault.sh vault-0 write kubernetes/internal/role/eso-creds-reader \
		bound_service_account_names="auth-sa" \
		bound_service_account_namespaces="eso" \
		policies="read_only" \
		ttl="15m"
	src/vault.sh vault-0 policy write read_only -<vault/read_only.hcl

assets/cluster-keys.json.gpg:
	: ## $@
	src/vault.sh vault-0 operator init \
    -key-shares=3 \
    -key-threshold=3 \
    -format=json \
  | gpg -aer esovault \
  | tee assets/cluster-keys.json.gpg

	gpg -u $(shell basename $(PWD)) \
			--output assets/cluster-keys.json.sign \
			--detach-sig assets/cluster-keys.json.gpg

vault/unseal: dist dist/unseal-keys.txt
	: ## $@
	cd dist

	<unseal-keys.txt xargs -n1 -- src/vault.sh vault-0 operator unseal

	src/vault.sh vault-1 operator raft join \
		http://vault-0.vault-internal:8200
	<unseal-keys.txt xargs -n1 -- src/vault.sh vault-0 operator unseal

	src/vault.sh vault-2 operator raft join \
		http://vault-0.vault-internal:8200
	<unseal-keys.txt xargs -n1 -- src/vault.sh vault-0 operator unseal

	kubectl get pods -n vault
	src/vault.sh vault-0 status

vault/seal:
	: ## $@
	src/vault.sh vault-0 operator seal
