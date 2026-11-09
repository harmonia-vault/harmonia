// Package keeper 是保管进程（设计文档 17.5）：在内存里保管手机批准的变量，直到授权结束。
// 它通过数据目录下的本机套接字服务同一用户的 harmonia 命令，从不把变量写到磁盘。
package keeper

import (
	"sort"
	"sync"

	"github.com/harmonia-vault/harmonia/cli/internal/api"
)

// Value 是保管的一个变量：环境 ID、环境里的名字和值。
type Value struct {
	EnvironmentID string `json:"environmentId"`
	Name          string `json:"name"`
	Value         string `json:"value"`
}

// Auth 是一项授权。Scope 为 terminal 时只对 Session（终端会话 ID）里的程序有效；
// ExpiresAt 为 0 表示长期（直到电脑重启或退出登录）。列出授权时不带 Values。
type Auth struct {
	ID        string             `json:"id"`
	Scope     string             `json:"scope"`
	ExpiresAt int64              `json:"expiresAt"`
	Session   int                `json:"session"`
	Items     []api.ApprovalItem `json:"items"`
	Values    []Value            `json:"values,omitempty"`
}

// Store 是保管进程内存里的授权，可以并发使用。
type Store struct {
	mu    sync.Mutex
	auths map[string]*Auth
}

func NewStore() *Store { return &Store{auths: map[string]*Auth{}} }

// Put 保存一项授权（同一 ID 再次保存时替换）。
func (s *Store) Put(a Auth) {
	a.Items = make([]api.ApprovalItem, len(a.Values))
	for i, v := range a.Values {
		a.Items[i] = api.ApprovalItem{EnvironmentID: v.EnvironmentID, Name: v.Name}
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.auths[a.ID] = &a
}

func (a *Auth) usable(session int, nowMs int64) bool {
	if a.ExpiresAt != 0 && a.ExpiresAt <= nowMs {
		return false
	}
	return a.Scope != "terminal" || a.Session == session
}

// Get 返回 items 中这个会话能用的变量；没有的不放进结果。同一个变量有多项授权时取最新保存的。
func (s *Store) Get(items []api.ApprovalItem, session int, nowMs int64) []Value {
	s.mu.Lock()
	defer s.mu.Unlock()
	want := map[[2]string]bool{}
	for _, it := range items {
		want[[2]string{it.EnvironmentID, it.Name}] = true
	}
	found := map[[2]string]Value{}
	for _, a := range s.auths {
		if !a.usable(session, nowMs) {
			continue
		}
		for _, v := range a.Values {
			if key := [2]string{v.EnvironmentID, v.Name}; want[key] {
				found[key] = v
			}
		}
	}
	out := make([]Value, 0, len(found))
	for _, it := range items {
		if v, ok := found[[2]string{it.EnvironmentID, it.Name}]; ok {
			out = append(out, v)
			delete(found, [2]string{it.EnvironmentID, it.Name})
		}
	}
	return out
}

// List 返回全部授权（不带变量值），按到期时间排列，长期的在最后。
func (s *Store) List() []Auth {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]Auth, 0, len(s.auths))
	for _, a := range s.auths {
		c := *a
		c.Values = nil
		out = append(out, c)
	}
	sort.Slice(out, func(i, j int) bool {
		ei, ej := out[i].ExpiresAt, out[j].ExpiresAt
		if (ei == 0) != (ej == 0) {
			return ej == 0
		}
		if ei != ej {
			return ei < ej
		}
		return out[i].ID < out[j].ID
	})
	return out
}

// Held 判断是否持有这项授权。
func (s *Store) Held(id string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, ok := s.auths[id]
	return ok
}

// End 结束一项授权，返回是否持有过。
func (s *Store) End(id string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, ok := s.auths[id]
	delete(s.auths, id)
	return ok
}

// EndAll 结束全部授权，返回它们的 ID。
func (s *Store) EndAll() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	ids := make([]string, 0, len(s.auths))
	for id := range s.auths {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	s.auths = map[string]*Auth{}
	return ids
}

// Prune 结束到期的授权，以及终端已经关闭（会话不在了）的“仅这个终端”授权，返回它们的 ID。
func (s *Store) Prune(nowMs int64, sessionAlive func(int) bool) []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	var ended []string
	for id, a := range s.auths {
		if (a.ExpiresAt != 0 && a.ExpiresAt <= nowMs) || (a.Scope == "terminal" && !sessionAlive(a.Session)) {
			delete(s.auths, id)
			ended = append(ended, id)
		}
	}
	sort.Strings(ended)
	return ended
}

// Empty 判断是否没有任何授权。
func (s *Store) Empty() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.auths) == 0
}
