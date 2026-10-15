package app

import (
	"context"
	"errors"
	"fmt"

	"github.com/harmonia-vault/harmonia/cli/internal/api"
	hc "github.com/harmonia-vault/harmonia/cli/internal/crypto"
)

// BatchItem 是批量写入的一项：Delete 为 true 时删除这个变量，否则写入 Entry。
type BatchItem struct {
	Name   string
	Entry  hc.Entry
	Delete bool
}

// 每批的上限（docs/protocol.md 3.2）：最多 100 项；请求体留出余量，不超过约 1.5 MB。
const (
	maxBatchItems = 100
	maxBatchBytes = 1_500_000
)

type batch struct {
	idx  []int
	set  []api.VarWrite
	del  []string
	size int
}

// WriteBatch 把各项加密后分批调用批量写入接口。一批整体成功或整体失败，返回每一项的错误（nil 表示成功），
// 顺序同 items。本机已被移除时返回 api.ErrRevoked，其余错误都记在各项上。
func WriteBatch(ctx context.Context, c *api.Client, envID string, key []byte, kv int, items []BatchItem) ([]error, error) {
	errs := make([]error, len(items))
	var batches []*batch
	cur := &batch{}
	for i, it := range items {
		size := len(it.Name) + 32
		var w *api.VarWrite
		if !it.Delete {
			ct, err := hc.EncryptVar(key, envID, kv, it.Name, it.Entry)
			if err != nil {
				errs[i] = err
				continue
			}
			w = &api.VarWrite{Name: it.Name, Value: ct}
			size += len(ct)
		}
		if len(cur.idx) >= maxBatchItems || (len(cur.idx) > 0 && cur.size+size > maxBatchBytes) {
			batches = append(batches, cur)
			cur = &batch{}
		}
		cur.idx = append(cur.idx, i)
		cur.size += size
		if w != nil {
			cur.set = append(cur.set, *w)
		} else {
			cur.del = append(cur.del, it.Name)
		}
	}
	if len(cur.idx) > 0 {
		batches = append(batches, cur)
	}
	for _, b := range batches {
		err := c.PatchVariables(ctx, envID, fmt.Sprint(kv), b.set, b.del, hc.NewID())
		if errors.Is(err, api.ErrRevoked) {
			return nil, err
		}
		for _, i := range b.idx {
			errs[i] = err
		}
	}
	return errs, nil
}
