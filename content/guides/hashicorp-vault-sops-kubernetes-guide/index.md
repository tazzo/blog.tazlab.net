+++
title = "Advanced Secret Management Strategies: HashiCorp Vault, SOPS, and the Kubernetes Ecosystem"
date = 2026-01-10T23:59:00Z
draft = false
description = "A comprehensive guide to secret management in Kubernetes using HashiCorp Vault and Mozilla SOPS, from homelab to enterprise."
tags = ["kubernetes", "vault", "sops", "security", "devops", "gitops"]
author = "Tazzo"
+++

## Cloud-Native Security Paradigms and the Inadequacy of Native Mechanisms

The evolution of infrastructure toward cloud-native models and the massive adoption of Kubernetes as a container orchestrator have introduced unprecedented security challenges. In this context, secret management—the handling of sensitive information such as API keys, database passwords, TLS certificates, and access tokens—has become the fundamental pillar of any modern security strategy. Traditionally, managing sensitive data was plagued by "sprawl," where credentials were often hardcoded directly into source code, stored in cleartext in configuration files, or insecurely exposed via environment variables. With the shift to microservices, the number of these credentials has grown exponentially, making manual methods not only insecure but also operationally unsustainable.

Kubernetes offers a native system for secret management, but in-depth technical analysis reveals structural limitations critical for production environments. By default, Kubernetes secrets are stored in etcd, the cluster's key-value database, using Base64 encoding. It is essential to emphasize that Base64 encoding does not constitute any form of encryption; its sole purpose is to allow the storage of arbitrary binary data. Without explicit configuration of Encryption at Rest for etcd, anyone who gains access to the storage backend or the API server with sufficient privileges can retrieve secrets in cleartext. Furthermore, native secrets lack advanced features such as automatic credential rotation, granular identity-based access control, and a robust audit logging system that can track who accessed a secret and when.

To address these needs, the DevOps landscape has integrated specialized tools like HashiCorp Vault and Mozilla SOPS. Vault acts as a central authority for secrets, providing a unified control plane that transcends the individual Kubernetes cluster. SOPS, on the other hand, solves the challenge of integrating secrecy with version control systems (Git), allowing sensitive data to be encrypted before being stored in repositories. The combination of these tools, supported by automation via Terraform, allows for building secure and resilient CI/CD pipelines suitable for both a small homelab and large-scale professional infrastructures.

## Internal Architecture of HashiCorp Vault: The Heart of Secret Management

HashiCorp Vault is not a simple encrypted database but a comprehensive framework for identity-based security. Its architecture is designed around the concept of a cryptographic barrier that protects all data stored in the backend. When Vault is started, it is in a "sealed" state. In this state, Vault can access its physical storage but cannot decrypt the data contained within it, as the Master Key is not available in memory.

### The Unseal Process and the Shamir Algorithm

The unlocking process, known as "unseal," traditionally requires reconstructing the Master Key. Vault uses Shamir's Secret Sharing algorithm to split the Master Key into multiple fragments (key shares). A specified minimum number of these fragments (threshold) must be provided to reconstruct the master key and allow Vault to decrypt the data encryption key (Barrier Key). In Kubernetes environments, where pods are ephemeral and can be frequently rescheduled, manual unsealing is impractical. For this reason, the Auto-unseal feature is almost universally adopted, delegating the protection of the Master Key to an external KMS service (such as AWS KMS, Azure Key Vault, or Google Cloud KMS) or to another Vault cluster via the Transit engine.

### Secret Engines and Authentication Methods

Vault's flexibility stems from its Secret Engines and Auth Methods. While KV (Key-Value) engines store static secrets, dynamic engines can generate credentials "on-the-fly" for databases, cloud providers, or messaging systems. These credentials have a limited time-to-live (TTL) and are automatically revoked upon expiration, drastically reducing the "blast radius" in case of compromise.

| Vault Component | Main Function | Application in Kubernetes |
| :---- | :---- | :---- |
| **Barrier** | Cryptographic barrier between storage and API | Protection of sensitive data in etcd or Raft |
| **Storage Backend** | Data persistence (e.g., Raft, Consul) | Storage of secrets on Persistent Volumes |
| **Secret Engines** | Generation/Storage of secrets | Management of PKI certificates, dynamic DB credentials |
| **Auth Methods** | Verification of client identity | Integration with Kubernetes ServiceAccounts |
| **Audit Broker** | Logging of every request/response | Monitoring access for compliance and security |

## Implementing Vault on Kubernetes: Raft and High Availability

Deploying Vault on Kubernetes requires careful planning to ensure data availability and persistence. The modern approach recommended by HashiCorp involves using Integrated Storage based on the Raft consensus protocol. Unlike external backends like Consul, Raft allows Vault to autonomously manage data replication within the cluster, simplifying the topology and reducing the number of components to monitor.

### Cluster Topology and Quorum

A resilient Vault implementation requires an odd number of nodes to avoid "split-brain" scenarios. In production, a minimum of three nodes is recommended to tolerate the failure of a single node, while a five-node configuration is preferable to handle the loss of two nodes or an entire availability zone without service interruption. Each node participates in replicating the Raft log, ensuring that every write operation is confirmed by the majority before being considered definitive.

### Helm Chart Configurations and Hardening

Installation typically occurs via the official HashiCorp Helm chart. Critical configurations include enabling the server.ha.enabled module and defining storage via volumeClaimTemplates to ensure that each Vault replica has its own dedicated persistent volume. To maximize security, workload isolation must be implemented. Vault should not share nodes with other applications to mitigate side-channel attack risks. This is achieved using nodeSelector, tolerations, and affinity rules to confine Vault pods to dedicated hardware.

An often overlooked aspect is the configuration of liveness and readiness probes. Since a Vault instance can be active but sealed, the readiness probe must be intelligently configured to distinguish between a running process and a service ready to respond to decryption requests. The Helm chart handles much of this logic, using CLI commands like vault status to verify the internal state of the node.

## Terraform: The Connective Tissue of DevOps Automation

Terraform integrates into the ecosystem as the Infrastructure as Code (IaC) tool of choice, allowing the configuration of not only the underlying infrastructure (Kubernetes clusters, networks, storage) but also access policies and secrets within Vault. Terraform's value lies in its ability to manage dependencies between different providers.

### Lifecycle Management and Dependencies

Using the hashicorp/vault provider allows operators to define secrets, policies, and authentication configurations declaratively. At the same time, the hashicorp/kubernetes provider allows mapping this information within the cluster. A common pattern involves extracting a secret from Vault via a data source and subsequently creating it as a Kubernetes secret for legacy applications that do not support native integration with Vault.

### State File Security and Sensitive Variables

A critical challenge in using Terraform is protecting the state file (terraform.tfstate). This file often contains sensitive information in cleartext, including secrets retrieved from Vault during the plan or apply phase. It is imperative to store the state in a secure remote backend, such as AWS S3 with server-side encryption and state locking (DynamoDB), or use HashiCorp Terraform Cloud which natively manages state encryption at rest. Additionally, variables marked as sensitive = true prevent Terraform from printing their values in the console output, reducing the risk of exposure in CI/CD pipeline logs.

| Terraform Strategy | Security Benefit | Mitigated Risk |
| :---- | :---- | :---- |
| **Encrypted Remote Backend** | State encryption at rest | Unauthorized access to secrets in tfstate |
| **Sensitive Variables** | Obfuscation of values in logs | Accidental exposure in CI/CD stdout |
| **Vault Provider** | Centralized secret management | Hardcoding credentials in .tf files |
| **RBAC for the Control Plane** | Limitation of who can execute apply | Unauthorized changes to critical infrastructure |

## Mozilla SOPS: Security for Version Control and GitOps Flows

Mozilla SOPS (Secrets OPerationS) was born from the need to integrate secrets into the Git-based workflow (GitOps) without compromising security. Unlike Kubernetes secrets, which should never be stored in Git even if encoded, files encrypted with SOPS are safe for versioning.

### Envelope Encryption and Multi-Recipient

SOPS implements envelope encryption, where data is encrypted with a symmetric Data Encryption Key (DEK), which is in turn encrypted by one or more Master Keys (KEK) managed externally. This approach allows for multiple recipients for the same secret: for example, a file can be decrypted by a team of administrators via their personal PGP keys and, simultaneously, by the Kubernetes cluster via a cloud KMS service.

### Integration with age for Operational Simplicity

While PGP has historically been the standard for SOPS, the tool age (Actually Good Encryption) has become the preferred choice for modern DevOps environments due to its simplicity, lack of complex configurations, and cryptographic speed. In an age-based workflow, each operator generates a key pair; the public key is inserted into the repository's .sops.yaml file, while the private key remains protected on the operator's machine or uploaded as a secret in the Kubernetes cluster.

YAML

# Esempio di file.sops.yaml  
creation_rules:
  - path_regex:.*\.enc\.yaml$
    encrypted_regex: ^(data|stringData)$
    age: age1vwd8j93mx9l99k... # Chiave pubblica del cluster  
    pgp: 0123456789ABCDEF...   # Chiave di backup dell'admin

The use of encrypted_regex is a fundamental best practice: it allows encrypting only sensitive values (such as the data and stringData fields of a Kubernetes secret) while leaving metadata like apiVersion, kind, and metadata.name in cleartext. This enables GitOps tools and operators to identify the resource type without having to decrypt it.

## Secret Consumption Mechanisms in Kubernetes

Once secrets have been stored in Vault or encrypted with SOPS, the workload running on Kubernetes must be able to access them. Three main patterns exist, each responding to different security and complexity requirements.

### 1. Vault Agent Injector

This method uses a Sidecar container automatically injected into pods via a Mutating Admission Webhook. The Vault Agent handles authentication with Vault using the pod's ServiceAccount and writes secrets to a shared memory volume (emptyDir). It is the ideal solution for applications that are not "cloud-native" and expect to read secrets from local files, as it allows formatting data via HCL or Go templates.

### 2. Vault Secrets Operator (VSO)

VSO represents the native approach for GitOps. The operator monitors custom resources (CRDs) in the cluster, retrieves data from Vault, and creates/updates standard Kubernetes secrets. This method is extremely powerful because it allows applications to use native Kubernetes secrets (mounted as volumes or environment variables) without any code changes, while maintaining Vault as the single source of truth.

### 3. Secrets Store CSI Driver

This driver allows mounting external secrets directly as volumes in the pod's file system, without ever creating a Kubernetes Secret object. This approach is considered the most secure since the secret exists only within the pod's ephemeral memory and disappears when the pod is terminated, reducing the persistence of sensitive data in the cluster.

| Integration Method | Storage in the Cluster | Dynamicity | Complexity |
| :---- | :---- | :---- | :---- |
| **Vault Agent Injector** | Memory volume (Sidecar) | Very High (Automatic renewal) | Medium |
| **Vault Secrets Operator** | Kubernetes Secret object | High (Periodic synchronization) | Low |
| **Secrets Store CSI** | Pod file system | High (On-the-fly update) | High |
| **Native K8s Secrets** | etcd (Base64) | None (Manual) | Minimal |

## The Secret Zero Problem and the Identity-Based Solution

The "Secret Zero" dilemma is a fundamental logical challenge in information security: to retrieve its secrets securely, an application needs an initial credential to prove its identity to the secret manager. If this initial credential is hardcoded into the container image or passed as an insecure environment variable, the entire system becomes vulnerable.

### Cryptographic Identity Attestation

The modern solution to Secret Zero consists of shifting the focus from "what you possess" (a password) to "who you are" (a verifiable identity). In Kubernetes, this is achieved via Vault's Kubernetes authentication method. When a pod attempts to access Vault, it sends its ServiceAccount JWT token, which is automatically injected by Kubernetes into the pod's file system. Vault receives this token and contacts the Kubernetes API server via a TokenReview request to verify that the token is valid and belongs to the declared ServiceAccount. Once the identity is confirmed, Vault issues a session token with limited privileges, eliminating the need to distribute bootstrap secrets.

### OIDC Federation in CI/CD

The same principle applies to CI/CD pipelines. Using OIDC (OpenID Connect) identity federation, a GitHub Actions or GitLab CI pipeline can obtain a temporary JWT token signed by the pipeline provider. Vault can be configured to trust this OIDC provider, verifying "claims" (such as repository name, branch, or environment) to decide whether to grant access to the secrets needed for deployment. This completely removes the need to store long-term Vault tokens within GitHub or GitLab secrets, effectively solving the Secret Zero problem for automation.

## Homelab Use Case: Implementation on Raspberry Pi with k3s, Flux, and SOPS

In a home context, resources are limited and operational simplicity is key. A Raspberry Pi 4 (with 4GB or 8GB of RAM) represents the ideal platform for running k3s, a lightweight Kubernetes distribution optimized for edge computing.

### Hardware and OS Preparation

Installation starts by using the Raspberry Pi Imager to write Raspberry Pi OS Lite (64-bit) to an SD card. A critical configuration for k3s is enabling cgroups in the /boot/firmware/cmdline.txt file, adding the parameters cgroup_memory=1 cgroup_enable=memory, without which the k3s service would fail to start correctly. To ensure stability, it is recommended to assign a static IP to the device via a DHCP reservation on the home router.

### GitOps Flow Configuration

In a homelab, managing secrets via SOPS and age keys is often preferred over installing a full Vault instance, due to the lower memory overhead. The workflow is structured as follows:

1.  **FluxCD Bootstrap:** Flux is installed on the cluster and connected to a private Git repository.
2.  **Key Management:** An age key pair is generated on the management machine. The private key is uploaded to the k3s cluster as a Kubernetes secret in the flux-system namespace.
3.  **Manifest Encryption:** Developers (i.e., homelab users) write their YAML manifests for applications like Pi-hole or Home Assistant, including the necessary credentials. These files are encrypted locally with SOPS before being committed.
4.  **Automatic Decryption:** When Flux detects a new commit, its Kustomize controller uses the age key present in the cluster to decrypt the manifests and apply them, ensuring that secrets are never exposed in cleartext in the repository.

This setup provides a professional-level experience with minimal cost and maximum security, allowing the entire home infrastructure to be managed as code.

## Professional Use Case: Enterprise Multi-Cluster Infrastructure

In a corporate environment, requirements for availability, audit, and Separation of Duties dictate a more complex architecture. Here, HashiCorp Vault becomes the nerve center of security.

### Multi-Cluster Reference Architecture

Enterprise best practice involves physical separation between the cluster hosting Vault (Tooling Cluster) and the clusters running application workloads (Production Clusters). This separation ensures that a potential "cluster failure" due to excessive application load does not prevent access to secrets, effectively blocking any recovery or autoscaling operations.

The Vault cluster must be deployed across three availability zones (AZ) to ensure high availability. Auto-unseal is implemented via the cloud provider's KMS service (e.g., AWS KMS) to eliminate the operational risk of manual unlocking.

### Advanced Integration with Terraform and CI/CD

In large organizations, Vault configuration is not done manually. Terraform pipelines are used to define:

*   **Granular Policies:** Each application has a dedicated policy that allows read-only access exclusively to the secret paths assigned to it.
*   **Centralized Audit Logging:** Vault is configured to send audit logs to a SIEM system (such as Splunk or Elasticsearch) for real-time anomaly detection.
*   **PKI as a Service:** Vault is used as an intermediate certificate authority (CA) to issue short-lived TLS certificates for pod-to-pod communication, often integrating with Service Meshes like Istio via cert-manager integration.

### Compliance and Governance

A fundamental pillar of production is secret rotation. While in a homelab rotation might be semi-annual and manual, in production it must be automated. Vault periodically rotates Master Keys and database credentials every 30 days or less, reducing the temporal validity of any stolen secret. This process is transparent to applications if integrated via the Vault Agent, which automatically updates the secret file on disk when it is rotated.

## Integration between Vault and SOPS: The Best of Both Worlds

A sophisticated evolution of the DevOps workflow consists of using Vault as the encryption backend for SOPS. Instead of relying on distributed age keys, SOPS uses Vault's Transit engine to encrypt the Data Encryption Key (DEK).

### The Hybrid Workflow

In this scenario, a developer who needs to modify an encrypted secret in Git does not need to possess a private key on their laptop. They simply need to authenticate to Vault (via corporate SSO). SOPS sends the encrypted DEK to Vault; Vault verifies the user's policies and, if authorized, decrypts the DEK and returns it to SOPS to unlock the file.

This approach offers unique advantages:

*   **No key distribution:** Cryptographic keys never leave Vault's security barrier.
*   **Instant Revocation:** If an employee leaves the company, simply disabling their Vault account prevents them from decrypting any secret in the Git repository, even if they have a local copy.
*   **Centralized Audit:** Every attempt to decrypt a secret in Git leaves a trace in the Vault logs, allowing for identification of who is accessing what sensitive information during development.

| Feature | SOPS only (age) | Vault only (Dynamic) | Hybrid (SOPS + Vault Transit) |
| :---- | :---- | :---- | :---- |
| **Source of Truth** | Git (Repository) | Vault (API) | Git (Encrypted) + Vault (Keys) |
| **Offline Access** | Yes (with private key) | No (requires connection) | No (requires authentication) |
| **Operation Audit** | Limited (Git logs) | Full (Vault logs) | Full for every decryption |
| **Key Management** | Manual (File distribution) | Automatic (HSM/KMS) | Centralized in Vault |

## Monitoring, Audit, and Operational Maintenance (Day 2)

Secret management does not end with initial implementation. Long-term success depends on "Day 2" operations, which include cluster health monitoring and rigorous auditing.

### Backup and Disaster Recovery Strategies

For Vault, backup is not just about data, but also the Master Keys. Using Raft, it is possible to take periodic snapshots of the cluster state via the vault operator raft snapshot save command. These snapshots must be stored in an S3 bucket with encryption and versioning enabled. In the event of total Kubernetes cluster failure, it is essential to have a documented procedure for restoring Vault from a snapshot on a new cluster, including reconnecting to the KMS service for Auto-unseal.

### Drift Detection and Auto-Healing

In GitOps ecosystems, drift occurs when the cluster's actual state diverges from the one defined in Git. Flux and ArgoCD constantly monitor this drift. If an administrator manually modifies a decrypted secret via kubectl edit, the GitOps controller will detect the discrepancy and overwrite the changes with the encrypted state present in Git. This ensures configuration immutability and prevents silent and potentially harmful changes.

### Log Analysis and Intrusion Detection

Vault audit logs are a gold mine for security. Sophisticated analysis should look for anomalous patterns, such as a sudden spike in secret read requests from a ServiceAccount that usually only reads a few, or attempts to access unauthorized paths. Integration with Machine Learning-based anomaly detection tools can help identify these behaviors before they lead to a large-scale data breach.

## Performance and Scalability Considerations

Introducing Vault and SOPS adds layers of abstraction that can affect performance. Network latency between the application and Vault is a critical factor, especially for applications making hundreds of secret requests per second.

### Optimization via Caching and Renewable Tokens

To reduce the load on Vault, the Vault Agent implements caching and token renewal mechanisms. Instead of requesting a new secret for every transaction, the agent can keep the secret in memory and periodically renew its "lease," reducing traffic to the Vault cluster. In multi-region environments, Vault performance replicas can be used to distribute data geographically, allowing applications to read secrets from the nearest Vault node, minimizing intercontinental latency.

### Load Management in Kubernetes

CPU and memory resources for Vault must be correctly sized. A Vault cluster with Raft storage requires high-performance disks with low seek times (high IOPS) to avoid delays in committing consensus logs.

Snippet di codice

T_{commit} = L_{network} + T_{disk\_write} + T_{consensus\_logic}

The simplified formula above highlights that the commit time of a secret ($T_{commit}$) is the sum of the network latency between nodes ($L_{network}$), the physical disk write time ($T_{disk\_write}$), and the computational overhead of the Raft protocol. In enterprise environments, the use of NVMe SSD storage is highly recommended to keep performance within safe levels.

## Operational Conclusions and Adoption Roadmap

Secret management is an incremental journey. For organizations starting today, the recommended roadmap is:

1.  **Phase 1 (Basic Hygiene):** Implement SOPS with age keys for all secrets stored in Git, immediately eliminating cleartext files.
2.  **Phase 2 (Centralization):** Install HashiCorp Vault in high availability on Kubernetes and migrate critical database secrets, implementing automatic rotation.
3.  **Phase 3 (Identity):** Enable the Kubernetes and OIDC authentication methods to eliminate the Secret Zero problem and move toward authentication based on infrastructure trust.
4.  **Phase 4 (Optimization):** Integrate SOPS with Vault Transit to centralize key management and implement advanced audit logging for every access to sensitive data.

By adopting these tools and methodologies, DevOps teams can ensure that security is not an obstacle to speed, but an accelerator that allows for deploying code in a secure, auditable, and resilient manner, from the modest resources of a Raspberry Pi to the vast infrastructures of the global cloud.

#### **Bibliografia**

1. Secrets Management in Kubernetes: Native Tools vs HashiCorp Vault - PufferSoft, accessed on January 8, 2026, [https://puffersoft.com/secrets-management-in-kubernetes-native-tools-vs-hashicorp-vault/](https://puffersoft.com/secrets-management-in-kubernetes-native-tools-vs-hashicorp-vault/)  
2. 10 Best Practices For Cloud Secrets Management (2025 Guide) | by Beck Cooper - Medium, accessed on January 8, 2026, [https://beckcooper.medium.com/10-best-practices-for-cloud-secrets-management-2025-guide-ffed6858e76b](https://beckcooper.medium.com/10-best-practices-for-cloud-secrets-management-2025-guide-ffed6858e76b)  
3. Secrets Management: Vault, AWS Secrets Manager, or SOPS? - DEV Community, accessed on January 8, 2026, [https://dev.to/instadevops/secrets-management-vault-aws-secrets-manager-or-sops-2ce1](https://dev.to/instadevops/secrets-management-vault-aws-secrets-manager-or-sops-2ce1)  
4. 5 best practices for secrets management - HashiCorp, accessed on January 8, 2026, [https://www.hashicorp.com/en/resources/5-best-practices-for-secrets-management](https://www.hashicorp.com/en/resources/5-best-practices-for-secrets-management)  
5. Kubernetes Secrets Management in 2025 - A Complete Guide - Infisical, accessed on January 8, 2026, [https://infisical.com/blog/kubernetes-secrets-management-2025](https://infisical.com/blog/kubernetes-secrets-management-2025)  
6. How HashiCorp's Solutions Suite Secures Kubernetes for Business Success, accessed on January 8, 2026, [https://somerford-ltd.medium.com/how-hashicorps-solutions-suite-secures-kubernetes-for-business-success-7a561ceee6fc](https://somerford-ltd.medium.com/how-hashicorps-solutions-suite-secures-kubernetes-for-business-success-7a561ceee6fc)  
7. How to Manage Kubernetes Secrets with Terraform - HashiCorp Developer, accessed on January 8, 2026, [https://developer.hashicorp.com/terraform/tutorials/kubernetes/kubernetes-provider](https://developer.hashicorp.com/terraform/tutorials/kubernetes/kubernetes-provider)  
8. Run Vault on Kubernetes - HashiCorp Developer, accessed on January 8, 2026, [https://developer.hashicorp.com/vault/docs/deploy/kubernetes](https://developer.hashicorp.com/vault/docs/deploy/kubernetes)  
9. Building a Secure and Efficient GitOps Pipeline with SOPS | by Paolo Carta | ITNEXT, accessed on January 8, 2026, [https://itnext.io/securing-secrets-in-a-gitops-environment-with-sops-dccd8e8952d9](https://itnext.io/securing-secrets-in-a-gitops-environment-with-sops-dccd8e8952d9)  
10. Secrets Management With GitOps and Kubernetes - Stakater, accessed on January 8, 2026, [https://www.stakater.com/post/secrets-management-with-gitops-and-kubernetes](https://www.stakater.com/post/secrets-management-with-gitops-and-kubernetes)  
11. HashiCorp Vault on production-ready Kubernetes: Architecture guide, accessed on January 8, 2026, [https://flowfactor.be/blogs/hashicorp-vault-on-production-ready-kubernetes-complete-architecture-guide/](https://flowfactor.be/blogs/hashicorp-vault-on-production-ready-kubernetes-complete-architecture-guide/)  
12. Master DevOps: Kubernetes, Terraform, & Vault | Kite Metric, accessed on January 8, 2026, [https://kitemetric.com/blogs/mastering-devops-practical-guide-to-kubernetes-terraform-and-vault](https://kitemetric.com/blogs/mastering-devops-practical-guide-to-kubernetes-terraform-and-vault)  
13. Vault on Kubernetes deployment guide - HashiCorp Developer, accessed on January 8, 2026, [https://developer.hashicorp.com/vault/tutorials/kubernetes/kubernetes-raft-deployment-guide](https://developer.hashicorp.com/vault/tutorials/kubernetes/kubernetes-raft-deployment-guide)  
14. Vault with integrated storage reference architecture - HashiCorp Developer, accessed on January 8, 2026, [https://developer.hashicorp.com/vault/tutorials/day-one-raft/raft-reference-architecture](https://developer.hashicorp.com/vault/tutorials/day-one-raft/raft-reference-architecture)  
15. How to Setup Vault in Kubernetes- Beginners Tutorial - DevOpsCube, accessed on January 8, 2026, [https://devopscube.com/vault-in-kubernetes/](https://devopscube.com/vault-in-kubernetes/)  
16. CI/CD Pipeline Security Best Practices: The Ultimate Guide - Wiz, accessed on January 8, 2026, [https://www.wiz.io/academy/application-security/ci-cd-security-best-practices](https://www.wiz.io/academy/application-security/ci-cd-security-best-practices)  
17. Manage Kubernetes resources with Terraform - HashiCorp Developer, accessed on January 8, 2026, [https://developer.hashicorp.com/terraform/tutorials/kubernetes/kubernetes-provider](https://developer.hashicorp.com/terraform/tutorials/kubernetes/kubernetes-provider)  
18. Terraform - HashiCorp Developer, accessed on January 8, 2026, [https://developer.hashicorp.com/terraform](https://developer.hashicorp.com/terraform)  
19. Terraform Project for Managing Vault Secrets in a Kubernetes Cluster - GitGuardian Blog, accessed on January 8, 2026, [https://blog.gitguardian.com/terraform-project-for-managing-vault-secrets-in-a-kubernetes-cluster/](https://blog.gitguardian.com/terraform-project-for-managing-vault-secrets-in-a-kubernetes-cluster/)  
20. Managing Secrets in Terraform: A Complete Guide, accessed on January 8, 2026, [https://ezyinfra.dev/blog/managing-secrets-in-terraform](https://ezyinfra.dev/blog/managing-secrets-in-terraform)  
21. Access secrets from Hashicorp Vault in Github Action to implement in Terraform code, accessed on January 8, 2026, [https://www.reddit.com/r/hashicorp/comments/1hzz3r4/access_secrets_from_hashicorp_vault_in_github/](https://www.reddit.com/r/hashicorp/comments/1hzz3r4/access_secrets_from_hashicorp_vault_in_github/)  
22. Securing Secrets in a GitOps Environment with SOPS | by Paolo Carta | ITNEXT, accessed on January 8, 2026, [https://itnext.io/securing-secrets-in-a-gitops-environment-with-sops-dccd8e8952d9](https://itnext.io/securing-secrets-in-a-gitops-environment-with-sops-dccd8e8952d9)  
23. Securely store secrets in Git using SOPS and Azure Key Vault - Patrick van Kleef, accessed on January 8, 2026, [https://www.patrickvankleef.com/2023/01/18/securely-store-secrets-with-sops-and-keyvault](https://www.patrickvankleef.com/2023/01/18/securely-store-secrets-with-sops-and-keyvault)  
24. Use vault as backend of sops - by Eric Mourgaya - Medium, accessed on January 8, 2026, [https://medium.com/@eric.mourgaya/use-vault-as-backend-of-sops-1141fcaab07a](https://medium.com/@eric.mourgaya/use-vault-as-backend-of-sops-1141fcaab07a)  
25. Secure Secret Management with SOPS in Terraform & Terragrunt - DEV Community, accessed on January 8, 2026, [https://dev.to/hkhelil/secure-secret-management-with-sops-in-terraform-terragrunt-231a](https://dev.to/hkhelil/secure-secret-management-with-sops-in-terraform-terragrunt-231a)  
26. Manage Kubernetes secrets with SOPS - Flux, accessed on January 8, 2026, [https://fluxcd.io/flux/guides/mozilla-sops/](https://fluxcd.io/flux/guides/mozilla-sops/)  
27. Managing secrets with SOPS in your homelab | code and society - codedge, accessed on January 8, 2026, [https://www.codedge.de/posts/managing-secrets-sops-homelab/](https://www.codedge.de/posts/managing-secrets-sops-homelab/)  
28. Using SOPS Secrets with Age - Federico Serini | Site Reliability Engineer, accessed on January 8, 2026, [https://www.federicoserinidev.com/blog/using_sops_secrets_with_age/](https://www.federicoserinidev.com/blog/using_sops_secrets_with_age/)  
29. From Zero to GitOps: Building a k3s Homelab on a Raspberry Pi with ... - Medium, accessed on January 8, 2026, [https://dev.to/shankar_t/from-zero-to-gitops-building-a-k3s-homelab-on-a-raspberry-pi-with-flux-sops-55b7](https://dev.to/shankar_t/from-zero-to-gitops-building-a-k3s-homelab-on-a-raspberry-pi-with-flux-sops-55b7)  
30. List Of Secrets Management Tools For Kubernetes In 2025 - Techiescamp, accessed on January 8, 2026, [https://blog.techiescamp.com/secrets-management-tools/](https://blog.techiescamp.com/secrets-management-tools/)  
31. Solving secret zero with Vault and OpenShift Virtualization - HashiCorp, accessed on January 8, 2026, [https://www.hashicorp.com/en/blog/solving-secret-zero-with-vault-and-openshift-virtualization](https://www.hashicorp.com/en/blog/solving-secret-zero-with-vault-and-openshift-virtualization)  
32. Secret Zero Problem: Risks and Solutions Explained - GitGuardian, accessed on January 8, 2026, [https://www.gitguardian.com/nhi-hub/the-secret-zero-problem-solutions-and-alternatives](https://www.gitguardian.com/nhi-hub/the-secret-zero-problem-solutions-and-alternatives)  
33. What is the Secret Zero Problem? A Deep Dive into Cloud-Native Authentication - Infisical, accessed on January 8, 2026, [https://infisical.com/blog/solving-secret-zero-problem](https://infisical.com/blog/solving-secret-zero-problem)  
34. Use Case: Solving the Secret Zero Problem - Aembit, accessed on January 8, 2026, [https://aembit.io/use-case/solving-the-secret-zero-problem/](https://aembit.io/use-case/solving-the-secret-zero-problem/)  
35. Integrating Azure DevOps pipelines with HashiCorp Vault, accessed on January 8, 2026, [https://www.hashicorp.com/en/blog/integrating-azure-devops-pipelines-with-hashicorp-vault](https://www.hashicorp.com/en/blog/integrating-azure-devops-pipelines-with-hashicorp-vault)  
36. HashiCorp Vault · Actions · GitHub Marketplace, accessed on January 8, 2026, [https://github.com/marketplace/actions/hashicorp-vault](https://github.com/marketplace/actions/hashicorp-vault)  
37. Use HashiCorp Vault secrets in GitLab CI/CD, accessed on January 8, 2026, [https://docs.gitlab.com/ci/secrets/hashicorp_vault/](https://docs.gitlab.com/ci/secrets/hashicorp_vault/)  
38. Tutorial: Authenticating and reading secrets with HashiCorp Vault - GitLab Docs, accessed on January 8, 2026, [https://docs.gitlab.com/ci/secrets/hashicorp_vault_tutorial/](https://docs.gitlab.com/ci/secrets/hashicorp_vault_tutorial/)  
39. Building a Self-Hosted Homelab: Deploying Kubernetes (K3s), NAS (OpenMediaVault), and Pi-hole for Ad-Free Browsing | by PJames | Medium, accessed on January 8, 2026, [https://medium.com/@james.prakash/building-a-self-hosted-homelab-deploying-kubernetes-k3s-nas-openmediavault-and-pi-hole-for-7390d5a59bac](https://medium.com/@james.prakash/building-a-self-hosted-homelab-deploying-kubernetes-k3s-nas-openmediavault-and-pi-hole-for-7390d5a59bac)  
40. Modern Java developement with Devops and AI – Modern Java developement with Devops and AI, accessed on January 8, 2026, [https://coresynapseai.com/](https://coresynapseai.com/)  
41. Secrets and configuration management in IaC: best practices in HashiCorp Vault and SOPS for security and efficiency - Semantive, accessed on January 8, 2026, [https://www.semantive.com/blog/secrets-and-configuration-management-in-iac-best-practices-in-hashicorp-vault-and-sops-for-security-and-efficiency](https://www.semantive.com/blog/secrets-and-configuration-management-in-iac-best-practices-in-hashicorp-vault-and-sops-for-security-and-efficiency)  
42. Managing Kubernetes in 2025: 7 Pillars of Production-Grade Platform Management, accessed on January 8, 2026, [https://scaleops.com/blog/the-complete-guide-to-kubernetes-management-in-2025-7-pillars-for-production-scale/](https://scaleops.com/blog/the-complete-guide-to-kubernetes-management-in-2025-7-pillars-for-production-scale/)  
43. Mastering GitOps with Flux and Argo CD: Automating Infrastructure as Code in Kubernetes, accessed on January 8, 2026, [https://www.clutchevents.co/resources/mastering-gitops-with-flux-and-argo-cd-automating-infrastructure-as-code-in-kubernetes](https://www.clutchevents.co/resources/mastering-gitops-with-flux-and-argo-cd-automating-infrastructure-as-code-in-kubernetes)  
44. Data Science - Noise, accessed on January 8, 2026, [https://noise.getoto.net/tag/data-science/](https://noise.getoto.net/tag/data-science/)