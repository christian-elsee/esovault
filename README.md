# esovault

Kubernetes orchestration workflow for external secrets operator and hosted hashicorp vault. Orchestration is encapsulated within a standard `make` workflow. All workflow targets are idempotent.

## vault

Orchestrate ha vault using `make` and `make install`

```sh
$ make
: ## distclean
...
```
```sh
$ make install
: ## install/vault
cd dist
helm upgrade vault hashicorp/vault \
  --install \
  --namespace vault \
  --create-namespace \
  --version 0.27.0 \
  --set='server.ha.enabled=true' \
  --set='server.ha.raft.enabled=true'
...
```

Initialize cluster using `make vault/init`. Subsequent calls will not effect cluster state.

```sh
$ make vault/init
: ## dist/unseal-key.txt
...
Success! You are now authenticated. The token information displayed below
is already stored in the token helper. You do NOT need to run "vault login"
```

Cluster keys are sealed/encrypted via gpg to `assets/cluster-keys.json.gpg`, alongside its detached signature, `assets/cluster-keys.json.sign`.
```sh
$ ls -lhat assets/cluster-keys.json.*
-rw-r--r-- 1 christian staff  566 Mar  7 13:00 assets/cluster-keys.json.sign
-rw-r--r-- 1 christian staff 1.2K Mar  7 10:58 assets/cluster-keys.json.gpg
```

Assets defined in `assets/*` are not commited. If either the signature or sealed key file is lost, you will need to tear down and rebuild the cluster. To reset the cluster to an initial state, run `make clean`, followed by `make` and `make install`.
```sh
$ make clean
: ## distclean
rm -rf dist
: ## clean
helm delete vault -n vault ||:
...
release "vault" uninstalled
```
```sh
$ make
...
```
```sh
$ make install
...
```
