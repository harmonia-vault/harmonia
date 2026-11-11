package main

import "testing"

func TestParseVarWrite(t *testing.T) {
	for _, tt := range []struct {
		args              []string
		target, name      string
		vaultOnly, hasVal bool
		value             string
	}{
		{args: []string{"set", "env-id", "ALIAS"}, target: "env-id", name: "ALIAS"},
		{args: []string{"set", "-AAAAAAAAAAAAAAAAAAAAA", "ALIAS"}, target: "-AAAAAAAAAAAAAAAAAAAAA", name: "ALIAS"},
		{args: []string{"rm", "--AAAAAAAAAAAAAAAAAAAA", "ALIAS"}, target: "--AAAAAAAAAAAAAAAAAAAA", name: "ALIAS"},
		{args: []string{"set", "环境", "ALIAS", "value"}, target: "环境", name: "ALIAS", hasVal: true, value: "value"},
		{args: []string{"set", "--vault", "vault-id", "ORIGINAL", ""}, target: "vault-id", name: "ORIGINAL", vaultOnly: true, hasVal: true},
		{args: []string{"set", "ORIGINAL", "--vault", "变量库", "--note", "备注"}, target: "变量库", name: "ORIGINAL", vaultOnly: true},
		{args: []string{"rm", "env-id", "ALIAS"}, target: "env-id", name: "ALIAS"},
		{args: []string{"rm", "--vault=vault-id", "ORIGINAL", "--yes"}, target: "vault-id", name: "ORIGINAL", vaultOnly: true},
	} {
		t.Run(tt.args[0]+"/"+tt.target+"/"+tt.value, func(t *testing.T) {
			f, err := parseFlags(tt.args, "vault=", "env=", "note=", "show", "yes")
			if err != nil {
				t.Fatal(err)
			}
			w, err := parseVarWrite(f)
			if err != nil || w.target != tt.target || w.name != tt.name || w.vaultOnly != tt.vaultOnly || (w.value != nil) != tt.hasVal {
				t.Fatalf("目标或变量解析错误：%+v %v", w, err)
			}
			if tt.hasVal && *w.value != tt.value {
				t.Fatalf("变量值错误：%q", *w.value)
			}
		})
	}
}

func TestParseVarWriteRejectsInvalidArguments(t *testing.T) {
	for _, args := range [][]string{
		{"set"}, {"set", "env-id"}, {"set", "--vault", "vault-id"},
		{"set", "--vault=", "A"}, {"set", "--vault", "vault-id", "E", "A", "value"},
		{"set", "--env", "env-id", "A"}, {"set", "env-id", "A", "--show"},
		{"rm", "env-id", "A", "value"}, {"rm", "--vault", "vault-id", "E", "A"},
		{"rm", "env-id", "A", "--note="},
	} {
		f, err := parseFlags(args, "vault=", "env=", "note=", "show", "yes")
		if err != nil {
			t.Fatal(err)
		}
		if _, err := parseVarWrite(f); err == nil {
			t.Errorf("参数无效时应拒绝：%v", args)
		}
	}
}
