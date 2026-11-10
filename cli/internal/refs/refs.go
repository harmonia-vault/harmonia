// Package refs 计算环境的最终名字：按引用顺序展开、找出被遮住的同名变量、保存前检查重名
// （docs/protocol.md 3.2，设计文档 17.1）。规则三端一致，见 vectors/refs.json。
package refs

import (
	"slices"
	"sort"

	"github.com/harmonia-vault/harmonia/cli/internal/api"
)

// Names 返回变量库里现存的变量名；不存在的变量库返回空。
type Names func(vaultID string) []string

// nameIn 是变量库里的 source 在这条引用下的名字。
func nameIn(r api.Ref, source string) string {
	for _, i := range r.Items {
		if i.Name == source && i.As != "" {
			return i.As
		}
	}
	return source
}

func sortedUnique(names []string) []string {
	out := slices.Clone(names)
	sort.Strings(out)
	return slices.Compact(out)
}

// Expand 按引用顺序展开最终名字：勾选只取存在的变量（按勾选顺序），全部变量按名字排序。
// 同名时排在前面的优先，其余放进 shadowed。
func Expand(refs []api.Ref, names Names) (items, shadowed []api.EnvItem) {
	items, shadowed = []api.EnvItem{}, []api.EnvItem{}
	seen := map[string]bool{}
	for _, r := range refs {
		existing := names(r.VaultID)
		var sources []string
		if r.Scope == "all" {
			sources = sortedUnique(existing)
		} else {
			for _, i := range r.Items {
				if slices.Contains(existing, i.Name) {
					sources = append(sources, i.Name)
				}
			}
		}
		for _, src := range sources {
			it := api.EnvItem{Name: nameIn(r, src), VaultID: r.VaultID, Source: src}
			if seen[it.Name] {
				shadowed = append(shadowed, it)
				continue
			}
			seen[it.Name] = true
			items = append(items, it)
		}
	}
	return items, shadowed
}

// Duplicates 是保存环境前的重名检查：勾选的变量不论是否存在都算，全部变量按现存的算。
// 返回重复的最终名字，按出现顺序，不重复列出。
func Duplicates(refs []api.Ref, names Names) []string {
	seen := map[string]bool{}
	dup := []string{}
	for _, r := range refs {
		var sources []string
		if r.Scope == "all" {
			sources = sortedUnique(names(r.VaultID))
		} else {
			for _, i := range r.Items {
				sources = append(sources, i.Name)
			}
		}
		for _, src := range sources {
			n := nameIn(r, src)
			if !seen[n] {
				seen[n] = true
			} else if !slices.Contains(dup, n) {
				dup = append(dup, n)
			}
		}
	}
	return dup
}
