---
title: "The Immutable Handover: Terraform, Flux, and the Birth of the Castle Factory"
date: 2026-02-01T07:00:00+01:00
draft: false
tags: ["kubernetes", "terraform", "fluxcd", "gitops", "automation", "devops", "security", "infisical"]
categories: ["Infrastructure", "Design Patterns"]
author: "Taz"
description: "Technical chronicle of an architectural revolution: how I transformed the Ephemeral Castle infrastructure into a modular factory, delegating pillar management to Flux and automating total rebirth with a single command."
---

# The Immutable Handover: Terraform, Flux, and the Birth of the Castle Factory

Systems engineering is not a linear process, but an evolution made of continuous simplifications. After achieving High Availability with a 5-node cluster, I realized the architecture still suffered from an original sin: overlapping responsibilities. Terraform was doing too much, and Flux was doing too little. In this technical chronicle, I document the final evolutionary leap of the **Ephemeral Castle**: its transformation into a true \"Infrastructure Factory\" where the IaC code acts only as a spark, delegating the entire construction of the pillars to the GitOps engine.

The session's objective was radical: reduce Terraform to the bare minimum, reorganize the repository to ensure total isolation between projects, and create a rebirth system capable of rising from the ashes with a single automated command.

---

## The Reasoning: The Aesthetic of IaC Minimalism

Initially, I had configured Terraform to install not only the Kubernetes cluster but also all its fundamental components: MetalLB for networking, Longhorn for storage, Traefik for ingress, and Cert-Manager for certificates. On paper, it seemed like a logical choice: a single command to have everything ready.

However, this choice created an identity conflict. Flux, my GitOps \"butler,\" was also trying to manage those same components by reading the manifests repository. The result was a constant duel between Terraform and Flux for control of the cluster, with the risk of drift and collisions at every update.

### The Choice: Only the Essential
I decided to implement a drastic refactoring. Terraform now manages only the **\"Kernel\"** of the Castle:
1.  **Physical Provisioning**: Creation of VMs on Proxmox and configuration of Talos OS.
2.  **External Secrets Operator (ESO)**: This is the only Kubernetes component I kept in Terraform. The reason is purely technical: for Flux to download apps, it often needs secrets (Git tokens, S3 keys). ESO must be there from the very first second to act as a bridge with Infisical EU.
3.  **Flux CD**: The final trigger. Terraform installs Flux and hands it the keys to the `tazlab-k8s` repository.

This separation transforms Terraform into a midwife: it helps the cluster be born and then steps aside. Flux becomes the sole sovereign of the infrastructure pillars. The advantage? Traefik or MetalLB updates now happen with a simple `git push`, without ever having to invoke Terraform for application changes.

---

## Phase 1: Project-Centric Reconstruction and Isolation

Until yesterday, the folder structure was divided by platform (`providers/proxmox/...`). It was a limited approach that didn't scale well in a multi-project or multi-cloud scenario.

### The Reasoning: Total Isolation
I decided to reorganize the entire `ephemeral-castle` repository following a project-oriented hierarchy. A project (like \"Blue\") must be able to exist on both Proxmox and AWS in a totally isolated manner, with its independent Terraform states and protected keys.

I implemented the following structure:
*   `clusters/blue/proxmox/`: The specific logic for the local cluster.
*   `clusters/blue/configs/`: A dedicated folder to host generated sensitive files (`kubeconfig`, `talosconfig`).

### Security and .gitignore
A common error in IaC is letting state files or configs slip into version control. I updated the `.gitignore` with a recursive and aggressive rule:
```text
**/configs/
*.tfstate*
```
This ensures that regardless of how many new clusters I create, their keys will remain confined to my protected workstation or the vault, never on GitHub.

---

## Phase 2: The Castle Remote - `destroy.sh` and `create.sh`

The true challenge of ephemeral infrastructure is the speed of rebirth. If recreating the cluster requires 10 manual commands, the infrastructure is not ephemeral; it's just exhausting. I decided to condense the entire operational intelligence into two orchestration scripts.

### The Investigation: The Terraform Block
The main problem was that `terraform destroy` failed systematically. The Kubernetes and Helm providers were trying to connect to the cluster to verify resource status before deleting them. But if the machines had already been reset or turned off, Terraform remained hung waiting for a response that would never come.

### The Solution: The State \"Purge\"
I resolved this stalemate by inserting a forced cleanup phase in the `destroy.sh` script. Before launching the destroyer, the script manually removes problematic resources from the local state:

```bash
# destroy.sh snippet
echo "🔥 Phase 1: Cleaning Terraform State..."
terraform state list | grep -E "flux_|kubernetes_|kubectl_|helm_" | xargs -n 1 terraform state rm || true
```

This command tells Terraform: *\"Forget you ever knew Flux or Helm, just think about deleting the VMs\"*. It is a surgical maneuver that unlocks the entire destruction process.

---

## Phase 3: The Struggle of Race Conditions

During the first tests of the `create.sh` script, the cluster was born, but services (like the blog) remained offline.

### Error Analysis: The MetalLB Webhook
I saw the MetalLB Pods in `Running` state, but Flux reported a cryptic error on the IP pool configurations:
`failed calling webhook \"l2advertisementvalidationwebhook.metallb.io\": connect: connection refused`

**The thought process:**
I initially suspected a network problem between nodes. I checked the `metallb-controller` logs and discovered the truth: the webhook process (which validates YAML files) takes a few seconds longer than the main controller to activate. Flux tried to inject the configuration at the wrong millisecond, received a rejection, and stalled.

### The Solution: The Patience of EndpointSlices
I updated the creation script to not just wait for the Pods, but to query Kubernetes until the webhook endpoint was actually **ready to serve**. I migrated the control logic from the old `Endpoints` resource (now deprecated) to the modern `EndpointSlice`.

However, even this logic required refinement: initially, a Bash syntax error in the wait loop blocked the rebirth right at the finish line. Fixing that bug was the last lesson of the day: in an orchestration script, the robustness of controls (using `grep -q` instead of fragile string comparisons) is what separates \"toy\" automation from professional-grade.

```bash
# create.sh logic update
echo "⏳ Waiting for MetalLB Webhook to be serving..."
until kubectl get endpointslice -n metallb-system -l kubernetes.io/service-name=metallb-webhook-service -o jsonpath='{range .items[*].endpoints[?(@.conditions.ready==true)]}{.addresses[*]}{"\n"}{end}' 2>/dev/null | grep -q "\."; do
  printf "."
  sleep 5
done
echo " Webhook ready!"
```

This granular check eliminated the last \"race condition\" preventing total automation.

---

## Phase 4: Idempotency and the Infisical Conflict

Another obstacle was the automatic backup of config files to Infisical EU. Terraform tried to create the `KUBECONFIG_CONTENT` secret, but if it already existed from the previous attempt, the API returned a `400 Bad Request: Secret already exists` error.

### The Reasoning: Preventive Import
Instead of trying to delete the secret (which requires elevated permissions and time), I decided to implement an **automatic import** logic. Before executing the final apply, the script tries to \"import\" the secret into the Terraform state. If it exists, Terraform takes control and updates it; if it doesn't, the error is ignored, and Terraform will create it normally.

```bash
# create.sh snippet
echo "🔗 Checking for existing configs on Infisical..."
terraform import -var-file=secrets.tfvars infisical_secret.kubeconfig_upload "$WORKSPACE_ID:$ENV_SLUG:$FOLDER_PATH:KUBECONFIG_CONTENT" || true
```

---

## Deep-Dive: The Concept of Handover

In this architecture, the concept of **Handover** is fundamental. It represents the exact moment when the responsibility for the cluster passes from provisioning (IaC) to continuous delivery (GitOps).

Why is this a significant technical term?
In a traditional system, Terraform is \"the state.\" If you want to change a Traefik port, you change the Terraform code. In the Castle, Terraform doesn't even know what Traefik is. Terraform only knows it must give birth to a cluster and install Flux.

This drastically reduces the **Blast Radius** of a Terraform error: if you get a line wrong in the IaC code, you risk breaking the VMs, but you will never break the blog's application logic, because that resides in another world (GitOps). It is the final separation between the \"machine\" and the \"purpose.\"

---

## The Factory in Action: How a New Project is Born

Thanks to this restructuring, creating a new cluster is no longer a work of craftsmanship but a production line process. If I wanted to create the \"Green\" cluster today, the procedure would be as follows:

1. **Provisioning (IaC)**:
   - Copy the `templates/proxmox-talos` folder to `clusters/green/proxmox`.
   - Modify the `terraform.tfvars` file by setting the new IPs, cluster name, and the new Infisical path (e.g., `/ephemeral-castle/green/proxmox`).
   - Prepare the secrets on Infisical in the new folder.

2. **Delivery (GitOps)**:
   - Create a new GitHub repository starting from the contents of `gitops-template`.
   - Enter the URL of this new repository in the `terraform.tfvars` file of the project folder.

3. **Spark**:
   - Run `./create.sh` from the project folder.

In less than 10 minutes, Terraform would create the machines, and Flux would start populating the new repository with the base components (MetalLB, Traefik, Cert-Manager) already pre-configured. This is the true power of the Castle: the ability to scale horizontally not just nodes, but entire digital ecosystems.

---

## Final Hardening: Kernel Cleanup and API v1

To conclude the day, I addressed two \"cleanup\" bugs that were cluttering the logs.

1.  **Kernel Modules**: Talos reported errors loading `iscsi_generic`. Investigating the documentation, I found that in recent versions, iSCSI modules have been merged. I removed the non-existent module from `talos.tf`, finally achieving a clean boot (\"Green Boot\").
2.  **Deprecations**: I migrated every Kubernetes resource managed by Terraform to `v1` versions (e.g., `kubernetes_secret_v1`). This doesn't change functionality but ensures the infrastructure is ready for upcoming major Kubernetes releases and silences annoying terminal warnings.

---

## Post-lab Reflections: The Triumph of Automation

Seeing the Castle rise with a single command was one of the most satisfying experiences of this journey.

### What we learned:
1.  **IaC as Bootstrapper**: Terraform is at its best when limited to creating foundations. The more Kubernetes code you put in Terraform, the more problems you'll have in the future.
2.  **The Importance of Retries**: In a distributed world, you cannot assume a command will work on the first try. Orchestration scripts must have the \"patience\" to wait for network services to warm up.
3.  **Isolation = Replicability**: Dividing by project and platform makes the Castle a true factory. Today I have a \"Blue\" cluster on Proxmox, but the structure is ready to give birth to a \"Green\" cluster on AWS in less than 10 minutes.

The Castle is now not just solid; it is **autonomous**. The walls are high, the butler (Flux) is at work, and the blog you are reading is living proof that code, when well-orchestrated, can create immutable and indestructible realities.

---
*End of Technical Chronicle - Phase 5: Automation and Handover*
