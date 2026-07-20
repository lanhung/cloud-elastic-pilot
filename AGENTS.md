# Project Description

Cloud Elastic Pilot is an ACK-oriented reproduction and adaptation of *Hooke: Diagnosing and Tuning Elasticity in Heterogeneous Kubernetes Clusters*. It is designed to collect and correlate real per-pod lifecycle events across the Node, Image, Pod, and Application layers, build multi-axis elasticity profiles, attribute scale-out bottlenecks, and generate operator-reviewed tuning recommendations. For ACK, it maps Hooke's Karpenter NodeClaim path to GOATScaler node-provisioning events. The initial phase focuses on CPU workloads and real ACK node autoscaling, while a later GPU phase will compare Dynamic Resource Allocation (DRA) with static Multi-Instance GPU (MIG) partitioning.

# Experimental Environment

Experiments run on Alibaba Cloud ACK Managed Pro with containerd, two fixed CPU workers, and a GOATScaler-managed elastic pool (`min=0`, `max=3` for smoke tests). Images come from same-region ACR; Kubernetes API, SLS, and Prometheus provide observations; MySQL 8.0+ stores experiment data. Use only real lifecycle events and record immutable versions and UTC timestamps for every run.

# Project Structure

## `docs/`

- `docs/paper/`: Local source papers; `hooke.pdf` is canonical and the directory is Git-ignored.
- `docs/metric/`: Event, metric, trace, formula, and data-quality definitions.
- `docs/plans/`: ACK experiment procedures and acceptance criteria.
- `docs/research/`: Research reports and supporting investigation notes.
