# G2-R3 post-run Gate review

- original_summary_result: **FAIL**
- corrected_result: **PASS_AFTER_GATE_FIX**
- run_id: `01KY19QCAVDPNMD6MA0V7J8QJ7`
- controller_errors: 0
- ingester_errors: 0
- raw_events: 69
- traces: 5/5 complete
- pod_unschedulable_events: 4
- pod_unschedulable_unique_pods: 2
- task_id_pods: 2
- unique_tasks: 1
- max_pods_per_task: 2
- new_elastic_nodes: 1
- new_ready_nodes: 1
- current_task_new_nodes: 1
- current_task_new_nodes_with_provider_id: 1
- task_id_precision: 1
- task_id_recall: 1
- attribution_conflicts: 0

## Original false failure

The execution-time Gate compared 2 unique task-ID Pods with 4
`POD_UNSCHEDULABLE` event rows. Each of the same two Pods emitted two
Unschedulable state updates, so the two sides used different counting units.

## Corrected evaluation

The Gate now compares `COUNT(DISTINCT pod_uid)` on both sides:

```text
task_id_pods = 2
pod_unschedulable_unique_pods = 2
```

All other Gate conditions already passed in the original summary. The raw
summary remains unchanged for audit; this file records the corrected post-run
decision.

## Timestamp-fallback verification

The new Node emitted `NODE_CREATED`, `ACK_PROVISION_TASK_UPDATED`,
`NODE_NOT_READY`, and `NODE_READY`. The zero source timestamp on
`NODE_NOT_READY` fell back to observed time with:

```text
approximate = 1
event_time_fallback = observed_time
```

No event batch was rejected.
