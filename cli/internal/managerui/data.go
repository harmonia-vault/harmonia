package managerui

import (
	"context"
	"net/http"

	"github.com/harmonia-vault/harmonia/cli/internal/api"
	"github.com/harmonia-vault/harmonia/cli/internal/app"
	"github.com/harmonia-vault/harmonia/cli/internal/manager"
)

// valuesOnly 把导入的值转成修改：导入不带备注，已有变量的备注保留。
func valuesOnly(vars map[string]string) map[string]app.VarChange {
	out := make(map[string]app.VarChange, len(vars))
	for n, v := range vars {
		out[n] = app.VarChange{Value: &v}
	}
	return out
}

// dataRoutes 是解锁后对变量库、环境和变量的操作。
func (s *Server) dataRoutes(mux *http.ServeMux) {
	type vaultRef struct{ Vault string }
	type envRef struct{ Env string }
	type envIn struct {
		Env  string
		Name string
		Refs []api.Ref
	}

	mux.HandleFunc("POST /api/vaults/list", op(s, func(_ context.Context, sess *manager.Session, _ none) (any, error) {
		return map[string]any{"vaults": sess.Vaults()}, nil
	}))
	mux.HandleFunc("POST /api/vaults/create", op(s, func(ctx context.Context, sess *manager.Session, in struct{ Name string }) (any, error) {
		id, err := sess.CreateVault(ctx, in.Name)
		return map[string]string{"id": id}, err
	}))
	mux.HandleFunc("POST /api/vaults/rename", op(s, func(ctx context.Context, sess *manager.Session, in struct{ Vault, Name string }) (any, error) {
		return nil, sess.RenameVault(ctx, in.Vault, in.Name)
	}))
	mux.HandleFunc("POST /api/vaults/delete", op(s, func(ctx context.Context, sess *manager.Session, in vaultRef) (any, error) {
		return nil, sess.DeleteVault(ctx, in.Vault)
	}))
	mux.HandleFunc("POST /api/vaults/names", op(s, func(_ context.Context, sess *manager.Session, in vaultRef) (any, error) {
		names, err := sess.VaultVarNames(in.Vault)
		return map[string]any{"names": names}, err
	}))

	mux.HandleFunc("POST /api/envs/list", op(s, func(_ context.Context, sess *manager.Session, _ none) (any, error) {
		return map[string]any{"envs": sess.Envs()}, nil
	}))
	mux.HandleFunc("POST /api/envs/get", op(s, func(_ context.Context, sess *manager.Session, in envRef) (any, error) {
		return sess.Env(in.Env)
	}))
	mux.HandleFunc("POST /api/envs/preview", op(s, func(_ context.Context, sess *manager.Session, in envIn) (any, error) {
		items, shadowed, dup := sess.Preview(in.Refs)
		return map[string]any{"items": items, "shadowed": shadowed, "duplicates": dup}, nil
	}))
	mux.HandleFunc("POST /api/envs/create", op(s, func(ctx context.Context, sess *manager.Session, in envIn) (any, error) {
		id, err := sess.CreateEnv(ctx, in.Name, in.Refs)
		return map[string]string{"id": id}, err
	}))
	mux.HandleFunc("POST /api/envs/save", op(s, func(ctx context.Context, sess *manager.Session, in envIn) (any, error) {
		return nil, sess.SaveEnv(ctx, in.Env, in.Name, in.Refs)
	}))
	mux.HandleFunc("POST /api/envs/delete", op(s, func(ctx context.Context, sess *manager.Session, in envRef) (any, error) {
		return nil, sess.DeleteEnv(ctx, in.Env)
	}))

	// 列表只返回变量名和值的长度；值在用户点开或编辑某一个变量时才单独取。
	mux.HandleFunc("POST /api/vars/list", op(s, func(_ context.Context, sess *manager.Session, in vaultRef) (any, error) {
		vars, err := sess.Vars(in.Vault)
		return map[string]any{"vars": vars}, err
	}))
	mux.HandleFunc("POST /api/vars/value", op(s, func(_ context.Context, sess *manager.Session, in struct{ Vault, Name string }) (any, error) {
		v, err := sess.Value(in.Vault, in.Name)
		return map[string]string{"value": v}, err
	}))
	mux.HandleFunc("POST /api/vars/set", op(s, func(ctx context.Context, sess *manager.Session, in struct {
		Vault string
		Vars  map[string]app.VarChange
	}) (any, error) {
		res, err := sess.SetVars(ctx, in.Vault, in.Vars)
		return map[string]any{"results": res}, err
	}))
	mux.HandleFunc("POST /api/vars/delete", op(s, func(ctx context.Context, sess *manager.Session, in struct {
		Vault string
		Names []string
	}) (any, error) {
		res, err := sess.DeleteVars(ctx, in.Vault, in.Names)
		return map[string]any{"results": res}, err
	}))

	type importIn struct {
		Vault string
		Text  string
		Names []string
	}
	mux.HandleFunc("POST /api/import/preview", op(s, func(_ context.Context, sess *manager.Session, in importIn) (any, error) {
		vars, names, errs := app.ParseDotenv(in.Text)
		items, err := sess.Diff(in.Vault, valuesOnly(vars), names)
		return map[string]any{"items": items, "errors": errs}, err
	}))
	mux.HandleFunc("POST /api/import/apply", op(s, func(ctx context.Context, sess *manager.Session, in importIn) (any, error) {
		vars, _, _ := app.ParseDotenv(in.Text)
		picked := map[string]app.VarChange{}
		for _, n := range in.Names {
			if v, ok := vars[n]; ok {
				picked[n] = app.VarChange{Value: &v}
			}
		}
		res, err := sess.SetVars(ctx, in.Vault, picked)
		return map[string]any{"results": res}, err
	}))

	type copyIn struct {
		From, To string
		Names    []string
	}
	mux.HandleFunc("POST /api/copy/preview", op(s, func(_ context.Context, sess *manager.Session, in copyIn) (any, error) {
		items, err := sess.CopyDiff(in.From, in.To, in.Names)
		return map[string]any{"items": items}, err
	}))
	mux.HandleFunc("POST /api/copy/apply", op(s, func(ctx context.Context, sess *manager.Session, in copyIn) (any, error) {
		res, err := sess.Copy(ctx, in.From, in.To, in.Names)
		return map[string]any{"results": res}, err
	}))
}
