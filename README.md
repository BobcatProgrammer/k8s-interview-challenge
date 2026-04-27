# k8s Challenge

A self-contained Kubernetes debugging challenge. Three services should be
running in the cluster — none of them are. Your job is to fix them.

---

## Prerequisites

| Tool | Install |
|------|---------|
| [kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installation) | `brew install kind` |
| [kubectl](https://kubernetes.io/docs/tasks/tools/) | `brew install kubectl` |
| [flux CLI](https://fluxcd.io/flux/installation/#install-the-flux-cli) | `brew install fluxcd/tap/flux` |
| [git](https://git-scm.com/downloads) | `brew install git` |
| Docker **or** Podman | [Docker Desktop](https://docs.docker.com/get-docker/) or [Podman Desktop](https://podman-desktop.io) |

Both Docker Desktop and Podman Desktop are supported on macOS, Windows, and Linux.
Internet access is required (to pull images on first run).

---

## Setup

```bash
chmod +x *.sh
./bootstrap.sh
```

Bootstrap takes **2–4 minutes**. It will:

- Start a local Gitea git server (used by Flux)
- Create a kind cluster named `challenge`
- Install Flux, pointed at this repository

When it finishes, the cluster is live and Flux is reconciling.

---

## The challenge

Three services are deployed to the `challenge` namespace:

- **database** — a simple data store, serves on port 8080
- **api** — a Python HTTP service that talks to the database, serves on port 8080
- **frontend** — an nginx service that sits in front of the api, serves on port 8080

They should all be running. They are not. Find out why and fix them.

**Rules:**

1. All fixes must be made by editing files in `gitops/` and committing.
   No `kubectl apply` or `kubectl edit` by hand.
2. Only edit files under `gitops/`. Do not modify `bootstrap.sh`, `teardown.sh`, or `kind-config.yaml`.

**Success criteria:**

```bash
kubectl get pods -n challenge
# All three pods should show:  READY 1/1   STATUS Running   RESTARTS 0
```

---

## Workflow

The sync chain: **local edit → `git push` → Gitea → Flux (every 30s) → cluster**

After editing a manifest, push it and watch the result:

```bash
./apply.sh "fix: correct the secret key"   # commit + push to Gitea
```

---

## Teardown

```bash
./teardown.sh
```

Removes the kind cluster and the Gitea container. Your local git history is preserved.
