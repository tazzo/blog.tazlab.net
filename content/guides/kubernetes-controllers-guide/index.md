+++
title = "The controller architecture in Kubernetes: comprehensive guide to the cloud-native automation engine"
date = 2026-01-07
draft = false
description = "A comprehensive guide to Kubernetes controllers, their architecture, and how they drive cloud-native automation."
tags = ["kubernetes", "controllers", "cloud-native", "architecture", "automation"]
author = "Tazzo"
+++

The success of Kubernetes as the *de facto* standard for container orchestration lies not only in its ability to abstract hardware or manage networking, but fundamentally in its operational model based on controllers. In a massively distributed system, manual workload management would be impossible; stability is instead guaranteed by a myriad of intelligent control loops working incessantly to maintain harmony between what the user declared and what actually happens on physical or virtual servers.1 A controller in Kubernetes is, in its purest essence, an infinite loop, a daemon that observes the shared state of the cluster through the API server and makes the necessary changes to ensure the current state converges towards the desired state.1 This paradigm, borrowed from systems theory and robotics, transforms infrastructure management from an imperative approach (do this) to a declarative one (I want this to be like this).2

## **Fundamentals and mechanisms of the control loop**

To understand controllers "from scratch", it is necessary to visualize the cluster not as a static set of containers, but as a dynamic organism regulated by an intelligent thermostat. In a room, the thermostat represents the controller: the user sets a desired temperature (the desired state), the thermostat detects the current temperature (the current state) and acts by turning the heating on or off to eliminate the difference.2 In Kubernetes, this process follows a rigid pattern named "Watch-Analyze-Act".4

The first pillar, the "Watch" phase, relies on the API server as the single source of truth. Controllers constantly monitor the resources within their purview, leveraging etcd's notification mechanisms to react in real-time to any change.3 When a user applies a YAML manifest, the API server stores the specification (spec) in etcd, and the corresponding controller immediately receives a signal.2

In the "Analyze" phase, the controller compares the specification with the state reported in the resource's status field. If the specification requires three replicas of an application but the status reports only two, the analysis identifies a discrepancy.2 Finally, in the "Act" phase, the controller does not act directly on the container, but sends instructions to the API server to create new objects (like a Pod) or remove existing ones.2 Other components, such as the kube-scheduler and the kubelet, will then perform the necessary physical actions.2 This decoupling ensures that each component is specialized and that the system can tolerate partial failures without losing global consistency.3

### **The Kube-Controller-Manager: the nerve center**

Logically, each controller is a separate process, but to reduce operational complexity, Kubernetes groups all core controllers into a single binary called kube-controller-manager.1 This daemon runs on the control plane and manages most of the built-in control loops.1 To optimize performance, the kube-controller-manager allows configuring concurrency, i.e., the number of objects that can be synchronized simultaneously for each controller type.1

| Controller | Concurrency Parameter | Default Value | Impact on Performance |
| :---- | :---- | :---- | :---- |
| **Deployment** | --concurrent-deployment-syncs | 5 | Update speed of stateless applications |
| **StatefulSet** | --concurrent-statefulset-syncs | Not specified (global) | Orderly management of stateful applications |
| **DaemonSet** | --concurrent-daemonset-syncs | 2 | Readiness of infrastructural services on new nodes |
| **Job** | --concurrent-job-syncs | 5 | Simultaneous batch processing capacity |
| **Namespace** | --concurrent-namespace-syncs | 10 | Speed of resource cleanup and termination |
| **ReplicaSet** | --concurrent-replicaset-syncs | 5 | Management of the desired number of replicas |

These parameters are crucial for administrators of large clusters; increasing these values can make the cluster more responsive but drastically increases the load on the control plane CPU and network traffic towards the API server.1

## **Detailed analysis of Workload controllers**

Application management in Kubernetes happens through abstractions called workload resources, each governed by a specific controller designed to solve unique orchestration problems.9

### **Deployment and ReplicaSet: the stateless standard**

The Deployment controller is probably the most used in the Kubernetes ecosystem. It provides declarative updates for Pods and ReplicaSets.5 When defining a Deployment, the controller does not create Pods directly, but creates a ReplicaSet, which in turn ensures that the exact number of Pods is always running.5

The true power of the Deployment lies in the management of update strategies, primarily the "RollingUpdate".11 During a rollout, the Deployment controller creates a new ReplicaSet with the new image version and begins scaling it up, while simultaneously scaling down the old ReplicaSet.15 This mechanism allows for zero-downtime updates and facilitates immediate rollback via the command kubectl rollout undo.18 Deployments are ideal for web applications, APIs, and microservices where individual Pods are considered ephemeral and interchangeable.9

### **StatefulSet: identity in distributed chaos**

Unlike stateless applications, many systems (such as databases or message queues) require that each instance has a persistent identity and a specific startup order.9 The StatefulSet controller manages the deployment and scaling of a set of Pods providing uniqueness guarantees.21

Each Pod receives a name derived from an ordinal index (e.g., $pod-0, pod-1, \dots, pod-N-1$) which remains constant even if the Pod is rescheduled on another node.17 Furthermore, the StatefulSet guarantees storage persistence: each Pod is associated with a specific PersistentVolume via a volumeClaimTemplate.17 If Pod db-0 fails, the controller will create a new one named db-0 and attach it to the same data volume as before, preserving the application state.17

### **DaemonSet: ubiquitous infrastructure**

The DaemonSet controller ensures that a copy of a Pod is running on all (or some) nodes of the cluster.5 When a new node is added to the cluster, the DaemonSet controller automatically adds the specified Pod to it.9 This is fundamental for services that must reside on every physical machine, such as log collectors (Fluentd, Logstash), monitoring agents (Prometheus Node Exporter), or network components (Calico, Cilium).9 It is possible to limit execution to a subset of nodes using label selectors or node affinity.22

### **Job and CronJob: finite execution**

While the previous controllers manage services that should run indefinitely, Job and CronJob manage tasks that must terminate successfully.9 The Job controller creates one or more Pods and ensures that a specific number of them terminate successfully.24 If a Pod fails due to a container or node error, the Job controller starts a new one until the success quota or the retry limit (backoffLimit) is reached.24

The CronJob extends this logic by allowing the execution of Jobs on a scheduled basis, using the standard Unix crontab format.27 This is ideal for nightly backups, periodic report generation, or database maintenance tasks.28

| Feature | Deployment | StatefulSet | DaemonSet | Job |
| :---- | :---- | :---- | :---- | :---- |
| **Workload Nature** | Stateless | Stateful | Infrastructural | Batch / One-off task |
| **Pod Identity** | Random (hash) | Stable ordinal | Tied to node | Temporary |
| **Storage** | Shared or ephemeral | Dedicated per replica | Local or specific | Ephemeral |
| **Startup Order** | Random / Parallel | Ordered sequential | Parallel on nodes | Parallel / Sequential |
| **Usage Example** | Nginx, Spring Boot | MySQL, Kafka, Redis | Fluentd, New Relic | DB Migration |

## **Internal controllers and system integrity**

Beyond user-visible controllers managing Pods, the Kubernetes control plane runs numerous "system" controllers that guarantee the functioning of the infrastructure itself.5

### **Node Controller**

The Node Controller is responsible for managing the lifecycle of nodes within the cluster.5 Its main functions include:

1. **Registration and Monitoring:** Keeps track of node inventory and their health status.6  
2. **Failure Detection:** If a node stops sending heartbeat signals (sign of a network or hardware failure), the Node Controller marks it as NotReady or Unknown.3  
3. **Pod Evacuation:** If a node remains unreachable for a prolonged period, the controller initiates the eviction of Pods managed by Deployment or StatefulSet so they can be rescheduled on healthy nodes.5

### **Namespace Controller**

Namespaces provide a logical isolation mechanism within a cluster.12 The Namespace Controller intervenes when a user requests the deletion of a namespace.5 Instead of an instant deletion, the controller starts an iterative cleanup process: it ensures that all associated resources (Pod, Service, Secret, ConfigMap) are correctly removed before definitively deleting the Namespace object from the etcd database.5

### **Endpoints and EndpointSlice Controller**

These controllers constitute the connective tissue between networking and workloads. The Endpoints Controller constantly monitors Services and Pods; when a Pod becomes "Ready" (according to its readiness probe), the controller adds the Pod's IP address to the Endpoints object corresponding to the Service.5 This allows kube-proxy to correctly route traffic.3 The EndpointSlice Controller is a more modern and scalable evolution that manages larger groupings of endpoints in clusters with thousands of nodes.5

### **Service Account and Token Controller**

Security within the cluster is mediated by Service Accounts, which provide an identity to processes running in Pods.12 The Service Account Controllers automatically create a "default" account for each new namespace and generate the secret tokens necessary for containers to authenticate with the API server for monitoring or automation operations.8

## **Cloud Controller Manager (CCM): The interface with providers**

In cloud installations (AWS, Azure, Google Cloud), Kubernetes must interact with external resources such as load balancers or managed disks.3 The Cloud Controller Manager (CCM) separates cloud-specific logic from Kubernetes core logic.6

The CCM runs three main control loops:

* **Service Controller:** When a Service of type LoadBalancer is created, this controller interacts with the cloud provider's APIs (e.g., AWS NLB/ALB) to instantiate an external load balancer and configure its targets towards the cluster nodes.5  
* **Route Controller:** Configures the routing tables of the cloud network infrastructure to ensure that packets destined for Pods can travel between different physical nodes.5  
* **Node Controller (Cloud):** Queries the cloud provider to determine if a node that has stopped responding has effectively been removed or terminated from the cloud console, allowing for quicker cleanup of cluster resources.5

## **Extreme extensibility: The Operator pattern and Custom Controllers**

One of Kubernetes' strengths is its ability to be extended beyond native capabilities.7 While built-in controllers manage general abstractions (Pod, Service), the Operator pattern allows managing complex applications by introducing "domain knowledge" directly into the control plane.16

### **Anatomy of an Operator**

An Operator is the union of two components:

1. **Custom Resource Definition (CRD):** Extends the API server allowing the creation of new object types (e.g., an object of type ElasticsearchCluster or PostgresBackup).7  
2. **Custom Controller:** A custom control loop that watches these new resources and implements specific operational logic, such as performing a backup before a database update or managing data re-sharding.7

Operators automate tasks that would normally require expert human intervention (a Site Reliability Engineer), such as quorum management in a distributed cluster or database schema migration during an application upgrade.16

### **Development Tools: Operator SDK and Kubebuilder**

Developing a custom controller from scratch is complex, as it requires managing caches, workqueues, and low-latency network interactions.34 Tools like **Operator SDK** (supported by Red Hat) and **Kubebuilder** (official Kubernetes SIGs project) provide Go language frameworks to generate boilerplate, manage object serialization, and implement the reconciliation loop efficiently.33

| Tool | Supported Languages | Key Features |
| :---- | :---- | :---- |
| **Operator SDK** | Go, Ansible, Helm | Integration with Operator Lifecycle Manager (OLM), ideal for enterprise integrations.33 |
| **Kubebuilder** | Go | Based on controller-runtime, provides clean abstractions for CRD and Webhook generation.33 |
| **Client-Go** | Go | Low-level library for total control, but with a very steep learning curve.33 |

## **Elastic Automation: Horizontal Pod Autoscaler (HPA)**

The Horizontal Pod Autoscaler (HPA) controller automates horizontal scaling, i.e., adding or removing Pod replicas in response to load.38

Operation follows a precise mathematical formula to calculate the number of desired replicas:  
$R	extsubscript{desired} = \lceil R	extsubscript{current} \times \frac{current_value}{target_value} \rceil$
 The HPA queries the Metrics Server (or an adapter for custom metrics like Prometheus) to obtain average resource usage.38 If usage exceeds the set threshold (e.g., 70% CPU), the HPA updates the replicas field of the target Deployment or StatefulSet.38 This allows the cluster to adapt to unexpected traffic spikes without manual intervention, while optimizing costs during periods of low activity.38

## **Practical Guide: Installation and Configuration of Controllers**

Most users interact with controllers through YAML manifest files. Here is how to configure and manage the main controllers with real examples.

### **Configuring a Deployment with Rollout strategies**

A well-configured Deployment must clearly define how to manage updates.

YAML

apiVersion: apps/v1  
kind: Deployment  
metadata:  
  name: api-service  
  labels:  
    app: api  
spec:  
  replicas: 4  
  strategy:  
    type: RollingUpdate  
    rollingUpdate:  
      maxSurge: 25%       \# Number of extra pods created during rollout  
      maxUnavailable: 25% \# Maximum number of pods that can be offline  
  selector:  
    matchLabels:  
      app: api  
  template:  
    metadata:  
      labels:  
        app: api  
    spec:  
      containers:  
      \- name: api-container  
        image: myrepo/api:v1.0.2  
        ports:  
        \- containerPort: 8080  
        readinessProbe:    \# Fundamental for the Deployment controller  
          httpGet:  
            path: /healthz  
            port: 8080

13

To manage this controller from CLI:

* View status: kubectl rollout status deployment/api-service.19  
* See history: kubectl rollout history deployment/api-service.15  
* Perform rollback: kubectl rollout undo deployment/api-service \---to-revision=2.15

### **Installing an Operator via Operator SDK**

The installation process of an Operator is more articulated than a native resource, as it requires registering new API types.36

1. **Installing CRDs:** kubectl apply \-f deploy/crds/db\_v1alpha1\_mysql\_crd.yaml. This teaches the API server what a "MySQLDatabase" is.34  
2. **RBAC Configuration:** kubectl apply \-f deploy/role.yaml and kubectl apply \-f deploy/role\_binding.yaml. This gives the controller permissions to create Pods and Services.36  
3. **Controller Deployment:** kubectl apply \-f deploy/operator.yaml. This starts the Pod containing the Operator source code.36  
4. **Instance Creation:** Once the Operator is running, the user creates a custom resource to instantiate the application:  
   YAML  
   apiVersion: db.example.com/v1alpha1  
   kind: MySQLDatabase  
   metadata:  
     name: production-db  
   spec:  
     size: 3  
     storage: 100Gi

   7

At this point, the Operator will take charge of the request and orchestrate the creation of necessary StatefulSets, Services, and backups.7

## **Controller Selection: Decision Matrix for Cloud Architects**

Identifying the correct controller is a critical architectural decision that influences the resilience and maintainability of the entire system.20

| Usage Scenarios | Controller to use | Why? |
| :---- | :---- | :---- |
| **API Gateway, Web Front-end, Stateless Microservices** | **Deployment** | Maximum scaling speed and ease of "rolling" updates.9 |
| **Databases (PostgreSQL, MongoDB), Queues (RabbitMQ), Stateful AI/ML** | **StatefulSet** | Ensures data remains coupled to correct instances and manages quorum.9 |
| **Monitoring, Log Forwarding, Network Proxy (Kube-proxy)** | **DaemonSet** | Ensures every node contributes to cluster observability and connectivity.20 |
| **Massive data processing, ML Model Training, DB Migrations** | **Job** | Manages tasks that must run to success, with built-in retry logic.23 |
| **Periodic backups, Cache cleaning, Scheduled log rotation** | **CronJob** | Time-based automation, replaces system cron for a containerized environment.27 |
| **Complex Software-as-a-Service (SaaS), Managed-like Database** | **Operator** | When operational logic requires specific steps (e.g., leader promotion) not covered by StatefulSet.7 |

## **Operational Best Practices and Troubleshooting**

Correctly managing controllers requires awareness of some common pitfalls that can destabilize the production environment.41

### **The importance of Probes: Liveness and Readiness**

The Deployment controller trusts the information provided by containers. If a container is "Running" but the application inside is stalled, the controller will not intervene unless a **Liveness Probe** is configured.9 Similarly, a **Readiness Probe** is essential during rollouts: it informs the controller when the new Pod is effectively ready to receive traffic, preventing the rollout from proceeding if the new version is failing silently.9

### **Resource Requests and Limits: The fuel of Controllers**

The scheduler and autoscaling controllers (HPA) depend entirely on resource declarations.41 Without requests, the scheduler might overcrowd a node, leading to degraded performance.9 Without limits, a single Pod with a memory leak could consume all node memory, causing the forced restart of critical system Pods (OOM Killing).41

### **Labels and Selectors: The "Collision" risk**

Controllers identify resources within their purview via label selectors.5 A common mistake is using overly generic labels (e.g., app: web) in shared namespaces. If two different Deployments use the same selector, their controllers will conflict, each attempting to manage the other's Pods, leading to continuous container creation and deletion.47 It is good practice to use unique and structured labels.

### **History Management and Rollback**

Kubernetes maintains a limited history of Deployment rollouts (by default, 10 revisions).21 It is important to monitor these limits to ensure one can revert to stable versions in case of serious incidents.15 The use of GitOps tools (like ArgoCD or Flux) that track desired state in a Git repository is the preferred recommendation for managing complex configurations without manual errors.14

## **Conclusions: Towards Cluster Autonomy**

The controller model in Kubernetes represents the culmination of modern distributed systems engineering. Understanding how different controllers interact with each other — from the Node Controller detecting a failure, to the Deployment responding by rescheduling Pods, up to the HPA scaling replicas — is what differentiates a passive Kubernetes user from an orchestration expert.2

The future of this technology is moving towards ever-greater specialization through Operators, which allow managing not just containers, but the entire business logic lifecycle, from AI-driven databases to software-defined networks. In this ecosystem, the YAML manifest is no longer just a configuration file, but a living contract that a host of intelligent controllers pledges to honor every second, ensuring the application remains always available, secure, and ready to scale.1

#### **Bibliography**

1. kube-controller-manager \- Kubernetes, accessed on December 31, 2025, [https://kubernetes.io/docs/reference/command-line-tools-reference/kube-controller-manager/](https://kubernetes.io/docs/reference/command-line-tools-reference/kube-controller-manager/)  
2. Controllers \- Kubernetes, accessed on December 31, 2025, [https://kubernetes.io/docs/concepts/architecture/controller/](https://kubernetes.io/docs/concepts/architecture/controller/)  
3. Kubernetes Control Plane: Ultimate Guide (2024) \- Plural, accessed on December 31, 2025, [https://www.plural.sh/blog/kubernetes-control-plane-architecture/](https://www.plural.sh/blog/kubernetes-control-plane-architecture/)  
4. Kube Controller Manager: A Quick Guide \- Techiescamp, accessed on December 31, 2025, [https://blog.techiescamp.com/docs/kube-controller-manager-a-quick-guide/](https://blog.techiescamp.com/docs/kube-controller-manager-a-quick-guide/)  
5. A controller in Kubernetes is a control loop that: \- DEV Community, accessed on December 31, 2025, [https://dev.to/jumptotech/a-controller-in-kubernetes-is-a-control-loop-that-23d3](https://dev.to/jumptotech/a-controller-in-kubernetes-is-a-control-loop-that-23d3)  
6. Basic Components of Kubernetes Architecture \- Appvia, accessed on December 31, 2025, [https://www.appvia.io/blog/components-of-kubernetes-architecture](https://www.appvia.io/blog/components-of-kubernetes-architecture)  
7. Understanding Custom Resource Definitions, Custom Controllers, and the Operator Framework in Kubernetes | by Damini Bansal, accessed on December 31, 2025, [https://daminibansal.medium.com/understanding-custom-resource-definitions-custom-controllers-and-the-operator-framework-in-5734739e012d](https://daminibansal.medium.com/understanding-custom-resource-definitions-custom-controllers-and-the-operator-framework-in-5734739e012d)  
8. Kubernetes Components, accessed on December 31, 2025, [https://kubernetes-docsy-staging.netlify.app/docs/concepts/overview/components/](https://kubernetes-docsy-staging.netlify.app/docs/concepts/overview/components/)  
9. The Guide to Kubernetes Workload With Examples \- Densify, accessed on December 31, 2025, [https://www.densify.com/kubernetes-autoscaling/kubernetes-workload/](https://www.densify.com/kubernetes-autoscaling/kubernetes-workload/)  
10. Workload Management \- Kubernetes, accessed on December 31, 2025, [https://kubernetes.io/docs/concepts/workloads/controllers/](https://kubernetes.io/docs/concepts/workloads/controllers/)  
11. Deployment vs StatefulSet vs DaemonSet: Navigating Kubernetes Workloads, accessed on December 31, 2025, [https://dev.to/sre_panchanan/deployment-vs-statefulset-vs-daemonset-navigating-kubernetes-workloads-190j](https://dev.to/sre_panchanan/deployment-vs-statefulset-vs-daemonset-navigating-kubernetes-workloads-190j)  
12. Controllers :: Introduction to Kubernetes, accessed on December 31, 2025, [https://shahadarsh.github.io/docker-k8s-presentation/kubernetes/objects/controllers/](https://shahadarsh.github.io/docker-k8s-presentation/kubernetes/objects/controllers/)  
13. Kubernetes Workload \- Resource Types & Examples \- Spacelift, accessed on December 31, 2025, [https://spacelift.io/blog/kubernetes-workload](https://spacelift.io/blog/kubernetes-workload)  
14. Kubernetes Configuration Good Practices, accessed on December 31, 2025, [https://kubernetes.io/blog/2025/11/25/configuration-good-practices/](https://kubernetes.io/blog/2025/11/25/configuration-good-practices/)  
15. How do you rollback deployments in Kubernetes? \- LearnKube, accessed on December 31, 2025, [https://learnkube.com/kubernetes-rollbacks](https://learnkube.com/kubernetes-rollbacks)  
16. Kubernetes Controllers vs Operators: Concepts and Use Cases ..., accessed on December 31, 2025, [https://konghq.com/blog/learning-center/kubernetes-controllers-vs-operators](https://konghq.com/blog/learning-center/kubernetes-controllers-vs-operators)  
17. Kubernetes StatefulSet vs. Deployment with Use Cases \- Spacelift, accessed on December 31, 2025, [https://spacelift.io/blog/statefulset-vs-deployment](https://spacelift.io/blog/statefulset-vs-deployment)  
18. kubectl rollout undo \- Kubernetes, accessed on December 31, 2025, [https://kubernetes.io/docs/reference/kubectl/generated/kubectl_rollout/kubectl_rollout_undo/](https://kubernetes.io/docs/reference/kubectl/generated/kubectl_rollout/kubectl_rollout_undo/)  
19. kubectl rollout \- Kubernetes, accessed on December 31, 2025, [https://kubernetes.io/docs/reference/kubectl/generated/kubectl_rollout/](https://kubernetes.io/docs/reference/kubectl/generated/kubectl_rollout/)  
20. Kubernetes Deployments, DaemonSets, and StatefulSets: a Deep ..., accessed on December 31, 2025, [https://www.professional-it-services.com/kubernetes-deployments-daemonsets-and-statefulsets-a-deep-dive/](https://www.professional-it-services.com/kubernetes-deployments-daemonsets-and-statefulsets-a-deep-dive/)  
21. StatefulSets \- Kubernetes, accessed on December 31, 2025, [https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/](https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/)  
22. Kubernetes DaemonSet: Examples, Use Cases & Best Practices \- Groundcover, accessed on December 31, 2025, [https://www.groundcover.com/blog/kubernetes-daemonset](https://www.groundcover.com/blog/kubernetes-daemonset)  
23. Mastering K8s Job Timeouts: A Complete Guide \- Plural, accessed on December 31, 2025, [https://www.plural.sh/blog/kubernetes-jobs/](https://www.plural.sh/blog/kubernetes-jobs/)  
24. What Are Kubernetes Jobs? Use Cases, Types & How to Run \- Spacelift, accessed on December 31, 2025, [https://spacelift.io/blog/kubernetes-jobs](https://spacelift.io/blog/kubernetes-jobs)  
25. How to Configure Kubernetes Jobs for Parallel Processing \- LabEx, accessed on December 31, 2025, [https://labex.io/tutorials/kubernetes-how-to-configure-kubernetes-jobs-for-parallel-processing-414879](https://labex.io/tutorials/kubernetes-how-to-configure-kubernetes-jobs-for-parallel-processing-414879)  
26. Understanding backoffLimit in Kubernetes Jobs | Baeldung on Ops, accessed on December 31, 2025, [https://www.baeldung.com/ops/kubernetes-backofflimit](https://www.baeldung.com/ops/kubernetes-backofflimit)  
27. CronJobs | Google Kubernetes Engine (GKE), accessed on December 31, 2025, [https://docs.cloud.google.com/kubernetes-engine/docs/how-to/cronjobs](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/cronjobs)  
28. CronJob in Kubernetes \- Automating Tasks on a Schedule \- Spacelift, accessed on December 31, 2025, [https://spacelift.io/blog/kubernetes-cronjob](https://spacelift.io/blog/kubernetes-cronjob)  
29. CronJob \- Kubernetes, accessed on December 31, 2025, [https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/](https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/)  
30. How to automate your tasks with Kubernetes CronJob \- IONOS UK, accessed on December 31, 2025, [https://www.ionos.co.uk/digitalguide/server/configuration/kubernetes-cronjob/](https://www.ionos.co.uk/digitalguide/server/configuration/kubernetes-cronjob/)  
31. Service Accounts | Kubernetes, accessed on December 31, 2025, [https://kubernetes.io/docs/concepts/security/service-accounts/](https://kubernetes.io/docs/concepts/security/service-accounts/)  
32. Operator pattern \- Kubernetes, accessed on December 31, 2025, [https://kubernetes.io/docs/concepts/extend-kubernetes/operator/](https://kubernetes.io/docs/concepts/extend-kubernetes/operator/)  
33. What Is The Kubernetes Operator Pattern? – BMC Software | Blogs, accessed on December 31, 2025, [https://www.bmc.com/blogs/kubernetes-operator/](https://www.bmc.com/blogs/kubernetes-operator/)  
34. Ultimate Guide to Kubernetes Operators and How to Create New Operators \- Komodor, accessed on December 31, 2025, [https://komodor.com/learn/kubernetes-operator/](https://komodor.com/learn/kubernetes-operator/)  
35. The developer's guide to Kubernetes Operators | Red Hat Developer, accessed on December 31, 2025, [https://developers.redhat.com/articles/2024/01/29/developers-guide-kubernetes-operators](https://developers.redhat.com/articles/2024/01/29/developers-guide-kubernetes-operators)  
36. A complete guide to Kubernetes Operator SDK \- Outshift | Cisco, accessed on December 31, 2025, [https://outshift.cisco.com/blog/operator-sdk](https://outshift.cisco.com/blog/operator-sdk)  
37. Build a Kubernetes Operator in six steps \- Red Hat Developer, accessed on December 31, 2025, [https://developers.redhat.com/articles/2021/09/07/build-kubernetes-operator-six-steps](https://developers.redhat.com/articles/2021/09/07/build-kubernetes-operator-six-steps)  
38. Kubernetes HPA [Horizontal Pod Autoscaler] Guide \- Spacelift, accessed on December 31, 2025, [https://spacelift.io/blog/kubernetes-hpa-horizontal-pod-autoscaler](https://spacelift.io/blog/kubernetes-hpa-horizontal-pod-autoscaler)  
39. HPA with Custom GPU Metrics \- Docs \- Kubermatic Documentation, accessed on December 31, 2025, [https://docs.kubermatic.com/kubermatic/v2.29/tutorials-howtos/hpa-with-custom-gpu-metrics/](https://docs.kubermatic.com/kubermatic/v2.29/tutorials-howtos/hpa-with-custom-gpu-metrics/)  
40. Horizontal Pod Autoscaler (HPA) with Custom Metrics: A Guide \- overcast blog, accessed on December 31, 2025, [https://overcast.blog/horizontal-pod-autoscaler-hpa-with-custom-metrics-a-guide-0fd5cf0f80b8](https://overcast.blog/horizontal-pod-autoscaler-hpa-with-custom-metrics-a-guide-0fd5cf0f80b8)  
41. 7 Common Kubernetes Pitfalls (and How I Learned to Avoid Them), accessed on December 31, 2025, [https://kubernetes.io/blog/2025/10/20/seven-kubernetes-pitfalls-and-how-to-avoid/](https://kubernetes.io/blog/2025/10/20/seven-kubernetes-pitfalls-and-how-to-avoid/)  
42. kubectl rollout history \- Kubernetes, accessed on December 31, 2025, [https://kubernetes.io/docs/reference/kubectl/generated/kubectl_rollout/kubectl_rollout_history/](https://kubernetes.io/docs/reference/kubectl/generated/kubectl_rollout/kubectl_rollout_history/)  
43. Install the Operator on Kubernetes | Couchbase Docs, accessed on December 31, 2025, [https://docs.couchbase.com/operator/current/install-kubernetes.html](https://docs.couchbase.com/operator/current/install-kubernetes.html)  
44. The Kubernetes Compatibility Matrix Explained \- Plural.sh, accessed on December 31, 2025, [https://www.plural.sh/blog/kubernetes-compatibility-matrix/](https://www.plural.sh/blog/kubernetes-compatibility-matrix/)  
45. A pragmatic look at the Kubernetes Threat Matrix | by Simon Elsmie | Beyond DevSecOps, accessed on December 31, 2025, [https://medium.com/beyond-devsecops/a-pragmatic-look-at-the-kubernetes-threat-matrix-d58504e926b5](https://medium.com/beyond-devsecops/a-pragmatic-look-at-the-kubernetes-threat-matrix-d58504e926b5)  
46. Tackle Common Kubernetes Security Pitfalls with AccuKnox CNAPP, accessed on December 31, 2025, [https://accuknox.com/blog/avoid-common-kubernetes-mistakes](https://accuknox.com/blog/avoid-common-kubernetes-mistakes)  
47. 7 Common Kubernetes Pitfalls in 2023 \- Qovery, accessed on December 31, 2025, [https://www.qovery.com/blog/7-common-kubernetes-pitfalls](https://www.qovery.com/blog/7-common-kubernetes-pitfalls)
