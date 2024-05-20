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

## env ##########################################
export NAME := $(shell basename $(PWD))
export PATH := dist/bin:$(PATH)
export KUBECONFIG ?= $(HOME)/.kube/config

## interface ####################################
all: distclean dist build check
install: install/chart vault/init install/crds
clean:
test:
status:
vault/unseal:
vault/seal:

## clean ########################################
distclean:
	: ## $@
	rm -rf dist
clean:
	: ## $@
	rm -rf artifacts/*

	helm delete --cascade foreground esovault ||:
	kubectl delete namespace $(NAME) --wait --cascade=foreground ||:
	kubectl delete namespace $(NAME)-test --wait --cascade=foreground ||:
	kubectl delete MutatingWebhookConfiguration,clusterrole,clusterrolebinding,crd \
		--all-namespaces \
		--selector "app.kubernetes.io/instance=$(NAME)" \
		--cascade=foreground \
		--wait ||:
	kubectl delete MutatingWebhookConfiguration,clusterrole,clusterrolebinding,crd \
		--all-namespaces \
		--selector "app.kubernetes.io/name=$(NAME)" \
		--cascade=foreground \
		--wait ||:
	#exit 33
	#kubectl delete all -n $(NAME) --all --cascade=foreground ||:
	#kubectl delete configmaps,secrets,crds -n $(NAME) --cascade=foreground --wait

	#kubectl delete all -n $(NAME)-test --all ||:

	#kubectl delete clusterresource
	# remove cluster-level resources
	#kubectl get 
	# remove persistent volumes
	#kubectl delete pvc --all -n $(NAME)  ||:
	#kubectl delete pv --all -n $(NAME) ||:
	#kubectl delete namespace $(NAME) ||:
	kubectl delete clustersecretstore vault ||:

## dist #########################################
dist:
	: ## $@
	mkdir -p $@/.   \
					 $@/env \
					 $@/bin

	# cp needed artifacts to build chart dist
	cp -rf policy $@/

	# cp chart directory structure, dependency files and any
	# existing artifacts
	find chart -type d -print0 \
		| tac -s "" \
		| xargs -0I% -- mkdir -p "$@/%"
	cp -f chart/Chart.* $@/chart
	cp -rf artifacts/charts $@/chart ||:

	# cp bin assets needed to manage charts against k8s cluster
	tar -tf assets/helm-$(shell uname -s)-$(shell uname -m)-* \
		| sed -n 1p \
		| xargs -I% -- \
			tar -xv \
					-f assets/helm-$(shell uname -s)-$(shell uname -m)-* \
					-C dist/bin \
					--strip-components=1 \
					%/helm

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
dist/env/unseal_keys: artifacts/cluster-keys.json.gpg
	: ## $@
	gpg --verify $<.sign $<
	gpg -d <$<
		| jq -re ".unseal_keys_b64[]" \
		| xargs \
	>$@
dist/env/VAULT_TOKEN: artifacts/cluster-keys.json.gpg
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

## build ########################################
artifacts/cluster-keys.json.gpg:
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

artifacts/checksum:
	: # $@
	# publish determinitive checksum to artifacts
	find chart \
		-type f \
    -exec md5sum {} + \
		| sort -k 2 \
		| md5sum \
		| cut -f1 -d" " \
		| tee $@ 

artifacts/charts:
	: ## $@
	# build chart dependencies and cache against artifacts
	helm dependency update dist/chart \
		--skip-refresh
	rsync -av --delete dist/chart/charts/ $@
	
build: artifacts/checksum artifacts/charts 
	: # $@
	# publish chart manifests to artifacts
	# use kustomize to generate chart resource manifests
	find chart -mindepth 1 -type d -print0 \
		| xargs -0I% -- sh -c 'kubectl kustomize % >dist/%/resources.yaml' _

	# generate single file chart resource manifest as a sanity check of the build process
	helm template $(NAME) dist/chart \
		--dependency-update \
		--render-subchart-notes \
		--create-namespace \
		--namespace "$(NAME)" \
		--set "name=$(NAME)" \
		--set "checksum=$(shell cat artifacts/checksum)" \
		--dry-run \
	>artifacts/manifest.yaml

check: dist/chart artifacts/checksum
	: ## $@
	# perform a client side dry run of helm install process as a santiy
	# check of helm workflow against the generated chart resources
	helm upgrade $(NAME) dist/chart \
		--install \
		--dry-run \
		--dependency-update \
		--render-subchart-notes \
		--create-namespace \
		--namespace "$(NAME)" \
		--set "name=$(NAME)" \
		--set "checksum=$(shell cat artifacts/checksum)" \
	| tee -a artifacts/log >/dev/null

## install ######################################
install: artifacts/checksum
	: ## $@
	tar -cv \
			-f artifacts/cluster-keys.tar.$(shell cat artifacts/checksum) \
			-C artifacts \
			-- cluster-keys.json.gpg \
				 cluster-keys.json.gpg.sign
	tar -tvf artifacts/cluster-keys.tar.$(shell cat artifacts/checksum)

install/chart: dist/chart
	: ## $@
	helm upgrade $(NAME) dist/chart \
		--install \
		--skip-crds \
		--wait \
		--dependency-update \
		--render-subchart-notes \
		--create-namespace \
		--namespace "$(NAME)" \
		--set "name=$(NAME)" \
		--set "checksum=$(shell cat artifacts/checksum)" 
	
install/crds: dist/chart/crds/resources.yaml
	: ## $@
	kubectl apply \
		-f dist/chart/crds/resources.yaml \
		-n "$(NAME)" \

## vault ########################################
vault/init: dist/VAULT_TOKEN \
						dist/cacrt \
						dist/KUBE_SERVER \
						dist/AUTH_SA_TOKEN \
						dist/CHECKSUM \
						vault/unseal
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
					checksum=$(shell cat dist/env/CHECKSUM)

vault/unseal: assets/keys dist/unseal_keys
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
test: distclean dist build
	: ## $@
	rsync -avh --delete t/ dist/t/

	# cd dist && prove -vr
	helm test $(NAME) -n $(NAME)

## status #######################################
status:
	: ## $@
	helm status $(NAME) -n $(NAME) --show-resources

