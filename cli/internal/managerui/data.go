package managerui

import (
	"context"
	"net/http"

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

// dataRoutes 是解锁后对环境和变量的操作。
func (s *Server) dataRoutes(mux *http.ServeMux) {
	type envRef struct{ Env string }

	mux.HandleFunc("POST /api/envs/list", op(s, func(_ context.Context, sess *manager.Session, _ none) (any, error) {
		return map[string]any{"envs": sess.Envs()}, nil
	}))
	mux.HandleFunc("POST /api/envs/create", op(s, func(ctx context.Context, sess *manager.Session, in struct{ Name string }) (any, error) {
		id, err := sess.CreateEnv(ctx, in.Name)
		return map[string]string{"id": id}, err
	}))
	mux.HandleFunc("POST /api/envs/rename", op(s, func(ctx context.Context, sess *manager.Session, in struct{ Env, Name string }) (any, error) {
		return nil, sess.RenameEnv(ctx, in.Env, in.Name)
	}))
	mux.HandleFunc("POST /api/envs/delete", op(s, func(ctx context.Context, sess *manager.Session, in envRef) (any, error) {
		return nil, sess.DeleteEnv(ctx, in.Env)
	}))

	// 列表只返回变量名和值的长度；值在用户点开或编辑某一个变量时才单独取。
	mux.HandleFunc("POST /api/vars/list", op(s, func(_ context.Context, sess *manager.Session, in envRef) (any, error) {
		vars, err := sess.Vars(in.Env)
		return map[string]any{"vars": vars}, err
	}))
	mux.HandleFunc("POST /api/vars/value", op(s, func(_ context.Context, sess *manager.Session, in struct{ Env, Name string }) (any, error) {
		v, err := sess.Value(in.Env, in.Name)
		return map[string]string{"value": v}, err
	}))
	mux.HandleFunc("POST /api/vars/set", op(s, func(ctx context.Context, sess *manager.Session, in struct {
		Env  string
		Vars map[string]app.VarChange
	}) (any, error) {
		res, err := sess.SetVars(ctx, in.Env, in.Vars)
		return map[string]any{"results": res}, err
	}))
	mux.HandleFunc("POST /api/vars/delete", op(s, func(ctx context.Context, sess *manager.Session, in struct {
		Env   string
		Names []string
	}) (any, error) {
		res, err := sess.DeleteVars(ctx, in.Env, in.Names)
		return map[string]any{"results": res}, err
	}))

	type importIn struct {
		Env   string
		Text  string
		Names []string
	}
	mux.HandleFunc("POST /api/import/preview", op(s, func(_ context.Context, sess *manager.Session, in importIn) (any, error) {
		vars, names, errs := manager.ParseDotenv(in.Text)
		items, err := sess.Diff(in.Env, valuesOnly(vars), names)
		return map[string]any{"items": items, "errors": errs}, err
	}))
	mux.HandleFunc("POST /api/import/apply", op(s, func(ctx context.Context, sess *manager.Session, in importIn) (any, error) {
		vars, _, _ := manager.ParseDotenv(in.Text)
		picked := map[string]app.VarChange{}
		for _, n := range in.Names {
			if v, ok := vars[n]; ok {
				picked[n] = app.VarChange{Value: &v}
			}
		}
		res, err := sess.SetVars(ctx, in.Env, picked)
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
