SHELL = /bin/bash
.DEFAULT_GOAL := all
.SHELLFLAGS := -euo pipefail $(if $(TRACE),-x,) -c
.ONESHELL:
.DELETE_ON_ERROR:
.PHONY: all \
				build \
				check \
				install \
				test \
				assets/keys \
				chart/* \
				vault/* \
				install/*

## env
export NAME := $(shell basename $(PWD))
export PATH := ./bin:$(PATH)
export KUBECONFIG ?= $(HOME)/.kube/config

## workflows
all: distclean dist build check
install: install/chart vault/init install/crds assets/keys
test: dist build
chart/lockfile: distclean dist
vault/unseal: assets/keys
vault/seal:

## recipes
distclean:
	: ## $@
	rm -rf dist
clean: distclean
	: ## $@
	rm -rf assets/cluster-keys.json.gpg \
				 assets/cluster-keys.json.gpg.sign
	helm uninstall $(NAME) \
		--cascade foreground \
		--wait \
		-n $(NAME) \
	||:

	# remove persistent volumes
	kubectl delete pvc --all -n $(NAME)  ||:
	kubectl delete pv --all -n $(NAME) ||:
	kubectl delete namespace $(NAME) ||:
	kubectl delete clustersecretstore vault ||:

## dist
dist:
	: ## $@
	mkdir -p $@ \
					 $@/bin \
					 $@/chart \
					 $@/chart/crds \
					 $@/chart/templates

	cp -rf assets src policy -- $@/
	cp Chart.* values.yaml -- $@/chart
	cp assets/helm-$(shell uname -s)-$(shell uname -m)-* \
		 $@/bin/helm
dist/ca.crt:
	: ## $@
	yq -re <$(KUBECONFIG) \
		'.clusters[0].cluster."certificate-authority-data"' \
	| base64 -d >$@
dist/k8s-host.txt:
	: ## $@
	yq -re <$(KUBECONFIG) \
		'.clusters[0].cluster.server' \
	| tee $@
dist/unseal-keys.txt: dist/assets/cluster-keys.json.gpg
	: ## $@
	gpg --verify $<.sign $<
	gpg -d <$< | jq -re ".unseal_keys_b64[]" \
		>$@
dist/root-token.txt: dist/assets/cluster-keys.json.gpg
	: ## $@
	gpg --verify $<.sign $<
	gpg -d <$< | jq -re ".root_token" >$@
dist/auth-sa-token.txt:
	: ## $@
	kubectl -n $(NAME) get secret auth-sa-token -ojson \
		| jq -re ".data.token" \
		| base64 -d >$@
dist/build.checksum:
	: ## $@
	kubectl kustomize resources/crds \
		| tee dist/chart/crds/resources.yaml
	kubectl kustomize resources/templates \
		| tee dist/chart/templates/resources.yaml

	helm dependency build dist/chart
	find dist/chart \
		-type f \
    -exec md5sum {} + \
	| sort -k 2 \
	| md5sum \
	| cut -f1 -d" " \
	| tee dist/build.checksum
dist/assets/cluster-keys.json.gpg:
	: ## $@
	src/vault.sh $(NAME)-0 operator init \
    -key-shares=3 \
    -key-threshold=3 \
    -format=json \
  | gpg -aer $(NAME) \
  | tee $@
	gpg -u $(shell basename $(PWD)) \
			--output $@.sign \
			--detach-sig $@

build: dist/build.checksum
	: ## $@
	cat dist/build.checksum

check: dist/chart
	: ## $@
	helm lint dist/chart --with-subcharts

## chart ########################################
chart/lockfile:
	: ## $@
	rm -rf dist/chart/Chart.lock
	helm dependency update dist/chart

## assets #######################################
assets/keys: dist/build.checksum \
						 dist/assets/cluster-keys.json.gpg \
						 dist/assets/cluster-keys.json.gpg.sign
	: ## $@
	cp -f dist/assets/cluster-keys.json.gpg assets
	cp -f dist/assets/cluster-keys.json.gpg.sign assets
	tar -cv \
			-f assets/cluster-keys.tar.$(shell cat dist/build.checksum) \
			-C assets \
			-- cluster-keys.json.gpg \
				 cluster-keys.json.gpg.sign
	tar -tvf assets/cluster-keys.tar.$(shell cat dist/build.checksum)

## install ######################################
install/crds: dist/chart/crds/resources.yaml
	: ## $@
	kubectl apply \
		-f dist/chart/crds/resources.yaml \
		-n "$(NAME)"
install/chart: dist/build.checksum
	: ## $@
	helm upgrade $(NAME) dist/chart \
		--install \
		--skip-crds \
		--wait \
		--dependency-update \
		--render-subchart-notes \
		--create-namespace \
		--namespace "$(NAME)" \
		--set sha="$(shell cat dist/build.checksum)"

## vault ########################################
vault/init: dist/root-token.txt \
						dist/ca.crt \
						dist/k8s-host.txt \
						dist/auth-sa-token.txt \
						vault/unseal
	: ## $@
	src/vault.sh $(NAME)-0 login "$$(cat dist/root-token.txt)"
	src/vault.sh $(NAME)-0 secrets enable -path=secrets kv-v2 ||:
	src/vault.sh $(NAME)-0 policy write read_only -<dist/policy/read_only.json
	src/vault.sh $(NAME)-0 auth enable -path=kubernetes/internal kubernetes ||:
	src/vault.sh $(NAME)-0 write auth/kubernetes/internal/config \
		token_reviewer_jwt="$$(cat dist/auth-sa-token.txt)" \
		kubernetes_host="$$(cat dist/k8s-host.txt)" \
		kubernetes_ca_cert="$$(cat dist/ca.crt)"
	src/vault.sh $(NAME)-0 write auth/kubernetes/internal/role/eso-creds-reader \
		bound_service_account_names="auth-sa" \
		bound_service_account_namespaces="$(NAME)" \
		policies="read_only" \
		ttl="15m"

vault/unseal: dist/unseal-keys.txt
	: ## $@
	<dist/unseal-keys.txt xargs -n1 -- src/vault.sh $(NAME)-0 operator unseal

	src/vault.sh $(NAME)-1 operator raft join \
		http://$(NAME)-0.$(NAME)-internal:8200
	<dist/unseal-keys.txt xargs -n1 -- src/vault.sh $(NAME)-1 operator unseal

	src/vault.sh $(NAME)-2 operator raft join \
		http://$(NAME)-0.$(NAME)-internal:8200
	<dist/unseal-keys.txt xargs -n1 -- src/vault.sh $(NAME)-2 operator unseal

	src/vault.sh $(NAME)-0 status
	src/vault.sh $(NAME)-1 status
	src/vault.sh $(NAME)-2 status
	kubectl get pods -n $(NAME)

vault/seal:
	: ## $@
	src/vault.sh $(NAME)-0 operator seal

## test #########################################
test:
	: ## $@
	rsync -avh --delete t/ dist/t/
	cd dist && prove -vr
