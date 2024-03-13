.DEFAULT_GOAL := @goal
.SHELLFLAGS := -eu -o pipefail -c
.PHONY: build test run
.ONESHELL:
.DELETE_ON_ERROR:

## env
export PATH := ./bin:$(PATH)
export KUBECONFIG ?= $(HOME)/.kube/config

## recipe
@goal: distclean dist build

distclean:
	: ## $@
	rm -rf dist
clean: distclean
	: ## $@
	rm -rf assets/cluster-keys.json.*
	helm uninstall eso -n eso ||:
	helm uninstall vault -n vault ||:
	helm uninstall esovault -n esovault ||:
	kubectl delete pvc --all -n vault ||:
	kubectl delete pv --all -n vault ||:
	kubectl delete namespace vault ||:
	kubectl delete namespace eso ||:
	kubectl delete clusterrolebinding role-tokenreview-binding -n default ||:

dist:
	: ## $@
	mkdir -p $@ \
					 $@/bin \
					 $@/charts \
					 $@/templates \
					 $@/crd
	cp assets/helm-$(shell uname -s)-$(shell uname -m)-* $@/bin/helm
	cp -rf \
		.helmignore \
		Chart.lock \
		Chart.yaml \
		src \
		policy \
	-- $@/
dist/ca.crt: dist
	: ## $@
	yq -re <$(KUBECONFIG) \
		'.clusters[0].cluster."certificate-authority-data"' \
	| base64 -d >$@
dist/k8s-host.txt: dist
	: ## $@
	yq -re <$(KUBECONFIG) \
		'.clusters[0].cluster.server' \
	| base64 -d >$@
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

build:
	: ## $@
	kubectl kustomize resources/eso \
		| tee dist/templates/eso.yaml
	kubectl kustomize resources/default \
		| tee dist/templates/default.yaml
	kubectl kustomize resources/crd \
		| tee dist/crd/crd.yaml

	helm dependency build dist
	find dist/charts dist/templates \
		-type f \
    -exec md5sum {} + \
	| sort -k 2 \
	| md5sum \
	| cut -f1 -d" " \
	| tee dist/checksum.txt

check:
	: ## $@
	helm lint

install: install/chart \
				 vault/init
	: ## $@
	helm list --failed --short --all-namespaces \
		| { ! grep -q ^ ; }
	helm status eso -n eso
	helm status vault -n vault
	helm status esovault --all-namespaces


install/chart: dist/checksum.txt
	: ## $@
	helm upgrade esovault dist \
		--install \
		--namespace esovault \
		--set sha=$(shell cat dist/checksum.txt)

vault/init: dist/root-token.txt \
						dist/ca.crt \
						dist/k8s-host.txt \
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
		kubernetes_host="$$(cat k8s-host.txt)" \
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
