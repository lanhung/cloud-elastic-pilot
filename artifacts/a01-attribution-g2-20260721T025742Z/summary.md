# Hooke ACK first smoke summary

- result: **FAIL**
- run_id: `01KY19QCAVDPNMD6MA0V7J8QJ7`
- run_name: `a01-attribution-g2-20260721T025742Z`
- kube_context: `kubernetes-admin-c6fda2390918a4086bad884e8086557bc`
- cluster_id: `c6fda2390918a4086bad884e8086557bc`
- experiment_namespace: `hooke-attribution-g2-20260721t025742z`
- raw_events: 69
- traces: 5
- expected_traces: 5
- complete_traces: 5
- pod_layer_samples: 5
- app_layer_samples: 5
- controller_errors: 0
- ingester_errors: 0
- node_scale_enabled: true
- second_node_scale_wave: false
- pod_unschedulable_events: 4
- observed_nodes: 2
- observed_node_ready_events: 2
- elastic_nodes_before: 2
- elastic_nodes_after: 3
- new_elastic_nodes: 1
- new_ready_nodes: 1
- current_task_new_nodes: 1
- current_task_new_nodes_with_provider_id: 1
- provision_requested_events: 2
- task_id_pods: 2
- observed_task_id_nodes: 2
- observed_provider_id_nodes: 2
- unique_tasks: 1
- max_pods_per_task: 2
- attribution_conflicts: 0
- task_id_precision: 1
- task_id_recall: 1

## Gate failures
- task-ID pods 2 != unschedulable pods 4

## Files
- events.tsv
- traces.tsv
- metrics.tsv
- calculation.json
- report.json
- attribution.json
- task-links.tsv
- new-node-events.tsv
- controller.log
- ingester.log
