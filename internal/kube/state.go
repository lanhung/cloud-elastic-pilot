package kube

import "sync"

type State struct {
	mu            sync.RWMutex
	fingerprints  map[string]string
	namespaceRuns map[string]string
	podProvision  map[string]ProvisionMetadata
	activeRun     string
}

type ProvisionMetadata struct {
	TaskID   string
	NodeName string
}

func NewState(defaultRun string) *State {
	return &State{
		fingerprints:  map[string]string{},
		namespaceRuns: map[string]string{},
		podProvision:  map[string]ProvisionMetadata{},
		activeRun:     defaultRun,
	}
}

func (s *State) Changed(key, fingerprint string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if previous, ok := s.fingerprints[key]; ok && previous == fingerprint {
		return false
	}
	s.fingerprints[key] = fingerprint
	return true
}

func (s *State) SetNamespaceRun(namespace, runID string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if runID == "" {
		delete(s.namespaceRuns, namespace)
	} else {
		s.namespaceRuns[namespace] = runID
	}
}

func (s *State) SetActiveRun(runID string) { s.mu.Lock(); s.activeRun = runID; s.mu.Unlock() }

func (s *State) SetPodProvision(podUID string, metadata ProvisionMetadata) {
	if podUID == "" || metadata.TaskID == "" {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.podProvision[podUID] = metadata
}

func (s *State) PodProvision(podUID string) (ProvisionMetadata, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	metadata, ok := s.podProvision[podUID]
	return metadata, ok
}

func (s *State) RunID(namespace string, annotations map[string]string) string {
	if annotations != nil && annotations["hooke.io/run-id"] != "" {
		return annotations["hooke.io/run-id"]
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	if run := s.namespaceRuns[namespace]; run != "" {
		return run
	}
	// The active run is a fallback for cluster-scoped signals such as Node
	// lifecycle events. Applying it to arbitrary namespaced objects would
	// attribute unrelated system and application Pods to a node-scale run.
	if namespace != "" {
		return ""
	}
	return s.activeRun
}
