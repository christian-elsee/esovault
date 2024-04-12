.DEFAULT_GOAL := all
.SHELLFLAGS := -euo pipefail $(if $(TRACE),-x,) -c
.ONESHELL:
.DELETE_ON_ERROR:
.PHONY: all \
				build \
				check \
				install \
				test \
				loadenv \
				assets/keys \
				chart/* \
				vault/* \
				install/*

## env ##########################################
export NAME := $(shell basename $(PWD))
export PATH := ./bin:$(PATH)
export KUBECONFIG ?= $(HOME)/.kube/config

## interface ####################################
all: distclean dist build check
install: install/chart vault/init install/crds assets/keys
chart/lockfile: distclean dist
vault/unseal: assets/keys
vault/seal:
test: distclean dist build
status:
loadenv: buildenv

## clean ########################################
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

## dist #########################################
dist:
	: ## $@
	mkdir -p $@ \
					 $@/env \
					 $@/bin \
					 $@/log \
					 $@/chart \
					 $@/chart/crds \
					 $@/chart/templates \
					 $@/chart/templates/tests

	cp -rf assets src policy -- $@/
	cp Chart.* values.yaml -- $@/chart
	cp assets/helm-$(shell uname -s)-$(shell uname -m)-* \
		 $@/bin/helm

dist/%: dist/env/%
	: ## $@
	cat $<
dist/env/cacrt:
	: ## $@
	yq -re <$(KUBECONFIG) \
		'.clusters[0].cluster."certificate-authority-data"' \
	| base64 -d >$@
dist/env/KUBE_SERVER:
	: ## $@
	yq -re <$(KUBECONFIG) \
		".clusters[0].cluster.server" \
	>$@
dist/env/unseal_keys: dist/assets/cluster-keys.json.gpg
	: ## $@
	gpg --verify $<.sign $<
	gpg -d <$<
		| jq -re ".unseal_keys_b64[]" \
		| xargs \
	>$@
dist/env/VAULT_TOKEN: dist/assets/cluster-keys.json.gpg
	: ## $@
	gpg --verify $<.sign $<
	gpg -d <$< \
		| jq -re ".root_token" \
	>$@
dist/env/auth_sa_token:
	: ## $@
	kubectl -n $(NAME) get secret auth-sa-token -ojson \
		| jq -re ".data.token" \
		| base64 -d \
	>$@
dist/env/CHECKSUM:
	: ## $@
	kubectl kustomize resources/crds \
		| tee dist/chart/crds/resources.yaml
	kubectl kustomize resources/templates \
		| tee dist/chart/templates/resources.yaml
	kubectl kustomize resources/tests \
		| tee dist/chart/templates/tests/resources.yaml

	find dist/chart \
		-type f \
    -exec md5sum {} + \
		| sort -k 2 \
		| md5sum \
		| cut -f1 -d" " \
	>$@

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

build: dist/CHECKSUM loadenv
build:
	: ## $@
	helm dependency build dist/chart
	helm template $(NAME) dist/chart \
		--skip-crds \
		--wait \
		--dependency-update \
		--render-subchart-notes \
		--create-namespace \
		--namespace "$(NAME)" \
	| envsubst >dist/chart.yaml

check: dist/CHECKSUM loadenv
	: ## $@
	helm lint dist/chart \
		--with-subcharts \
		--set checksum=$(CHECKSUM)

## chart ########################################
chart/lockfile: dist/chart/Chart.yaml
	: ## $@
	rm -rf dist/chart/Chart.lock
	helm dependency update dist/chart

## assets #######################################
assets/keys: dist/CHECKSUM \
						 dist/assets/cluster-keys.json.gpg \
						 dist/assets/cluster-keys.json.gpg.sign \
						 loadenv
	: ## $@
	cp -f dist/assets/cluster-keys.json.gpg assets
	cp -f dist/assets/cluster-keys.json.gpg.sign assets
	tar -cv \
			-f assets/cluster-keys.tar.$(CHECKSUM) \
			-C assets \
			-- cluster-keys.json.gpg \
				 cluster-keys.json.gpg.sign
	tar -tvf assets/cluster-keys.tar.$(shell cat dist/build.checksum)

## install ######################################
install/chart: dist/chart.yaml
	: ## $@
	kubectl apply \
		-f dist/chart.yaml \
		-n "$(NAME)"

install/crds: dist/chart/crds/resources.yaml
	: ## $@
	kubectl apply \
		-f dist/chart/crds/resources.yaml \
		-n "$(NAME)"

## vault ########################################
vault/init: dist/VAULT_TOKEN \
						dist/cacrt \
						dist/KUBE_SERVER \
						dist/AUTH_SA_TOKEN \
						dist/CHECKSUM \
						vault/unseal \
						loadenv
	: ## $@
	src/vault.sh $(NAME)-0 login "$(shell cat dist/root-token.txt)"
	src/vault.sh $(NAME)-0 secrets enable -path=secret -version=1 kv ||:
	src/vault.sh $(NAME)-0 policy write read_only -<dist/policy/read_only.json
	src/vault.sh $(NAME)-0 auth enable -path=kubernetes/internal kubernetes ||:
	src/vault.sh $(NAME)-0 write auth/kubernetes/internal/config \
		token_reviewer_jwt="$(shell cat dist/auth-sa-token.txt)" \
		kubernetes_host="$(shell cat dist/k8s-host.txt)" \
		kubernetes_ca_cert="$$(cat dist/ca.crt)" # this has to process subs to account for newlines
	src/vault.sh $(NAME)-0 write auth/kubernetes/internal/role/eso-creds-reader \
		bound_service_account_names="auth-sa" \
		bound_service_account_namespaces="$(NAME)" \
		policies="read_only" \
		ttl="15m"
	src/vault.sh $(NAME)-0 kv get secret/init \
		|| src/vault.sh $(NAME)-0 kv put \
				secret/init \
					checksum=$(shell cat dist/build.checksum)

vault/unseal: dist/unseal_keys loadenv
	: ## $@
	src/vault.sh $(NAME)-0 operator unseal $(unseal_keys)

	src/vault.sh $(NAME)-1 operator raft join \
		http://$(NAME)-0.$(NAME)-internal:8200
	src/vault.sh $(NAME)-1 operator unseal $(unseal_keys)

	src/vault.sh $(NAME)-2 operator raft join \
		http://$(NAME)-0.$(NAME)-internal:8200
	src/vault.sh $(NAME)-2 operator unseal $(unseal_keys)

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

	# cd dist && prove -vr
	helm test $(NAME) -n $(NAME)

## status #######################################
status:
	: ## $@
	helm status $(NAME) -n $(NAME) --show-resources

## loadenv ######################################
buildenv:
	: ## $@
	src/buildmkenv.sh dist/env >dist/env.mk

loadenv:
	$(eval include dist/env.mk)

testenv: loadenv
testenv:
	echo "$(CACRT)"
