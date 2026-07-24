package main

import (
	"fmt"
	"sort"
	"sync"
	"time"
)

type barrierSnapshot struct {
	Members          int   `json:"members"`
	Minimum          int   `json:"minimum"`
	JoinedCount      int   `json:"joinedCount"`
	JoinedRanks      []int `json:"joinedRanks"`
	Released         bool  `json:"released"`
	ReleasedAtNS     int64 `json:"releasedAtNs,omitempty"`
	CoordinatorRank  int   `json:"coordinatorRank"`
	AdmissionMembers int   `json:"admissionMembers"`
}

type barrierCoordinator struct {
	mu         sync.Mutex
	members    int
	minimum    int
	joined     map[int]time.Time
	releasedAt time.Time
	allJoined  chan struct{}
	allOnce    sync.Once
}

func newBarrierCoordinator(members, minimum int) (*barrierCoordinator, error) {
	if members < 1 || minimum < 1 || minimum > members {
		return nil, fmt.Errorf("invalid barrier dimensions n=%d k=%d", members, minimum)
	}
	return &barrierCoordinator{
		members:   members,
		minimum:   minimum,
		joined:    make(map[int]time.Time, members),
		allJoined: make(chan struct{}),
	}, nil
}

func (c *barrierCoordinator) Join(rank int, at time.Time) (barrierSnapshot, bool, error) {
	if rank < 0 || rank >= c.members {
		return barrierSnapshot{}, false, fmt.Errorf("rank %d is outside [0, %d)", rank, c.members)
	}
	if at.IsZero() {
		at = time.Now().UTC()
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	_, existed := c.joined[rank]
	if !existed {
		c.joined[rank] = at.UTC()
	}
	if c.releasedAt.IsZero() && len(c.joined) >= c.minimum {
		c.releasedAt = at.UTC()
	}
	if len(c.joined) == c.members {
		c.allOnce.Do(func() { close(c.allJoined) })
	}
	return c.snapshotLocked(), !existed, nil
}

func (c *barrierCoordinator) Snapshot() barrierSnapshot {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.snapshotLocked()
}

func (c *barrierCoordinator) AllJoined() <-chan struct{} {
	return c.allJoined
}

func (c *barrierCoordinator) snapshotLocked() barrierSnapshot {
	ranks := make([]int, 0, len(c.joined))
	for rank := range c.joined {
		ranks = append(ranks, rank)
	}
	sort.Ints(ranks)
	snapshot := barrierSnapshot{
		Members:          c.members,
		Minimum:          c.minimum,
		JoinedCount:      len(ranks),
		JoinedRanks:      ranks,
		Released:         !c.releasedAt.IsZero(),
		CoordinatorRank:  0,
		AdmissionMembers: c.members,
	}
	if snapshot.Released {
		snapshot.ReleasedAtNS = c.releasedAt.UnixNano()
	}
	return snapshot
}
