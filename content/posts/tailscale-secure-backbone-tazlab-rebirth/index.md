+++
title = "Tailscale: The Secure Backbone of TazLab's Rebirth"
date = 2026-03-24T14:35:00+00:00
draft = false
tags = ["Tailscale", "Terraform", "Infrastructure-as-Code", "TazPod", "Security", "Networking", "Zero Trust", "DevOps", "OAuth", "Automation"]
description = "How I built the connective tissue for TazLab's rebirth: a Tailscale network entirely managed via IaC, without temporary keys and integrated into the TazPod vault."
author = "Tazzo"
+++

# Tailscale: The Secure Backbone of TazLab's Rebirth

## Introduction: The Connective Tissue Between Two Worlds

In the journey of rebuilding TazLab that I described in [previous articles](/posts/bootstrap-from-zero-vault-s3-rebirth/), we have reached a critical point. We have a plan to resurrect the infrastructure from a single S3 bucket and we have locked down the bootstrap credentials by eliminating them from the disk thanks to TazPod and AWS SSO. But there was one element still missing: the "invisible thread" that allows these components to talk to each other in a secure, private, and provider-agnostic way.

Today's goal was not just to "activate a VPN." The goal was to design and implement the **networking foundation** of TazLab as a pure Infrastructure-as-Code (IaC) resource. No manual configurations in the Tailscale console, no temporary authentication keys that expire after 90 days forcing manual intervention. I looked for a solution that was eternal, declarative, and integrated into the ephemeral lifecycle of my clusters.

---

## The Problem with Pre-auth Keys: A Predicted Technical Debt

The standard way to add nodes to a Tailnet is using **Pre-auth Keys**. They are convenient for a quick setup, but they present three fundamental problems for an infrastructure aiming for total automation:

1.  **Expiry**: Even if set to the maximum duration, they expire. This means if my cluster needs to scale or be reborn after six months, the bootstrap will fail because the key injected into the code or secrets is no longer valid.
2.  **Manual Management**: Generating a new key requires human action in the Tailscale UI. It is the opposite of the "Bootstrap from Zero" principle I am pursuing.
3.  **Lack of IaC Traceability**: You cannot define a Pre-auth Key in Terraform in a way that it is automatically recreated without external intervention except through convoluted workarounds.

The correct architectural solution is the use of an **OAuth Client**. A Tailscale OAuth Client is not a key, but an identity that can *generate* authentication keys on the fly. It never expires (unless explicitly revoked) and can be managed programmatically. This is the component I decided to place at the heart of the TazLab network.

---

## The IaC Phase: Ephemeral-Castle Expands

I started by creating a new directory in the infrastructure configurations repository: `ephemeral-castle/tailscale/`. Here I deposited the Terraform code that governs the entire network.

### The Declarative Heart: `acl.json`

Instead of writing access policies directly in the Terraform HCL, I chose to maintain a separate `acl.json` file. This choice is not aesthetic: Tailscale ACLs are a complex JSON and having a dedicated file allows for independent validation and extreme clarity in reading.

The applied philosophy is **Tag-based Zero Trust**. No node has access to the network just because it is "on the LAN." Access is granted only if the node possesses a specific tag. I defined five fundamental tags:

*   `tag:tazlab-vault`: The Vault cluster nodes on Oracle Cloud.
*   `tag:tazlab-k8s`: The main K8s cluster nodes on Proxmox/AWS.
*   `tag:vault-api`: The specific identity of the Vault proxy.
*   `tag:tazlab-db`: The specific identity of the database proxy.
*   `tag:tazpod`: My administration workstation.

The **Least Privilege** principle is rigorously applied: the K8s cluster can talk to Vault only on port `8200`, and only through the proxy tag. Nodes do not see each other at the OS level; they only see the necessary services.

```json
{
  "tagOwners": {
    "tag:tazlab-vault": ["roberto.tazzoli@gmail.com"],
    "tag:tazlab-k8s":   ["roberto.tazzoli@gmail.com"],
    "tag:vault-api":    ["roberto.tazzoli@gmail.com"],
    "tag:tazlab-db":    ["roberto.tazzoli@gmail.com"],
    "tag:tazpod":       ["roberto.tazzoli@gmail.com"]
  },
  "acls": [
    {
      "action":  "accept",
      "src":     ["tag:tazlab-vault"],
      "dst":     ["tag:tazlab-vault:8201"]
    },
    {
      "action":  "accept",
      "src":     ["tag:tazlab-k8s"],
      "dst":     ["tag:vault-api:8200"]
    },
    { "action": "accept", "src": ["tag:tazpod"], "dst": ["tag:tazlab-vault:6443,50000", "tag:tazlab-k8s:6443,50000"] }
  ]
}
```

During implementation, I encountered an interesting validation error: Terraform returned `Error: ACL validation failed: json: unknown field "comment"`. This is a classic example of a discrepancy between the UI (which allows inline comments in ACLs) and the pure JSON API, which does not accept them. I had to clean the `acl.json` file of every comment to allow Terraform to apply it successfully.

---

## The Discovery (The "Aha!" Moment): Terraform and the OAuth Client

Initially, my plan included using `curl` within a bootstrap script to create the OAuth Client, as many dated guides suggested that the Tailscale Terraform provider did not yet support this resource.

I started writing the `setup.sh` script using `curl`, but kept receiving `404 page not found` errors. I tried debugging the URL, changing the format (using `-` for the tailnet name, or the full Tailnet ID), but without success. Troubleshooting was becoming frustrating.

Instead of insisting on the error, I decided to take a step back and analyze the source code of the `tailscale/tailscale ~> 0.17` Terraform provider. It was the breakthrough: I discovered that the `tailscale_oauth_client` resource **exists and is perfectly functional**.

I deleted the `curl` script and rewrote everything in Terraform:

```hcl
# OAuth client for bootstrap (generates pre-auth keys)
resource "tailscale_oauth_client" "bootstrap" {
  description = "tazlab-bootstrap"
  scopes      = ["auth_keys", "devices"]
  tags        = ["tag:tazpod"]
}
```

This discovery radically changed the quality of the work. Now the identity that generates the network keys is a managed resource, tracked in `terraform.tfstate`, and recreatable with a single command. Idempotency is no longer a wish, but a technical reality.

### The TagOwners Problem

Another obstacle presented itself immediately after: `requested tags [tag:tazpod] are invalid or not permitted (400)`.
To create an OAuth Client that can assign a tag, the user (or the API key) performing the operation must be explicitly declared as the "owner" of that tag in the `tagOwners` section of the ACLs. I had to update `acl.json` to include my email for every tag before Terraform could successfully create the OAuth client. It is a fundamental security detail: Tailscale prevents a compromised identity from creating new clients with arbitrary tags to which it has no access.

---

## Integration with TazPod: Closing the Security Circle

Once the OAuth Client was generated via Terraform, the problem became: where do we save the `client_id` and the `client_secret`? They cannot be in the git repository (obviously), and I didn't want to save them in an insecure local file.

I used the **TazPod RAM Vault**. I updated the `setup.sh` orchestration script so that, after Terraform execution, it automatically extracts the secrets from the outputs:

```bash
# Extract credentials from Terraform
OAUTH_CLIENT_ID=$(terraform output -raw oauth_client_id)
OAUTH_CLIENT_SECRET=$(terraform output -raw oauth_client_secret)

# Save them into the TazPod RAM vault
echo "$OAUTH_CLIENT_ID"     > ~/secrets/tailscale-oauth-client-id
echo "$OAUTH_CLIENT_SECRET" > ~/secrets/tailscale-oauth-client-secret

# Sync with S3
(cd /workspace && tazpod save && tazpod push vault)
```

Now, the rebirth cycle is complete for the network as well. When I run `tazpod unlock`, the secrets needed to connect to the Tailnet are mounted in memory. Any new cluster or TazPod instance can use these credentials to join the network in less than a second.

---

## Empirical Verification: The Live Test

Theory is nice, but systems must work. I performed a live test by installing Tailscale directly into the `tazpod-lab` container (which didn't include it yet). This lack was the trigger for an immediate update of TazPod's layer hierarchy: Tailscale must be part of the base image's DNA.

After starting the `tailscaled` daemon in userspace mode (necessary because the container does not have permissions to create `tun` interfaces on the host kernel), I attempted to connect using the credentials just saved in the vault:

```bash
ID=$(cat ~/secrets/tailscale-oauth-client-id)
SECRET=$(cat ~/secrets/tailscale-oauth-client-secret)

sudo tailscale up \
  --client-id="$ID" \
  --client-secret="$SECRET" \
  --hostname=tazpod-lab \
  --advertise-tags=tag:tazpod \
  --reset
```

The result was instantaneous:
`active login: tazpod-lab.magellanic-gondola.ts.net`
`IP: 100.73.57.110`

The node appeared in the network, correctly tagged as `tag:tazpod`, with key expiry automatically disabled by the system (standard Tailscale behavior for tagged nodes).

---

## Post-Lab Reflections: What We Learned

This session consolidated TazLab's networking foundation in three ways:

1.  **Provider Independence**: It doesn't matter if a cluster runs on OCI, AWS, or in my living room. If it has the Tailscale extension and the OAuth Client, it is part of the TazLab private network instantaneously.
2.  **Zero Maintainability**: By switching to OAuth Clients managed via IaC, I eliminated the risk of failures due to key expirations. The network is now a "living" entity that manages itself.
3.  **Integrated Security**: The chain of trust that starts with AWS SSO and passes through the TazPod RAM Vault now also protects network access.

The next step in the roadmap is the provisioning of the **tazlab-vault** cluster on Oracle Cloud. Thanks to today's work, that cluster will be born already talking privately with the rest of my world, without me ever having to expose its port 8200 to public internet traffic.

The network is there. The ephemeral castle now has its invisible walls.
