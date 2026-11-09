package refs

import (
	"encoding/json"
	"os"
	"reflect"
	"testing"

	"github.com/harmonia-vault/harmonia/cli/internal/api"
)

// 三端共用的展开规则向量（vectors/refs.json）。
func TestVectors(t *testing.T) {
	data, err := os.ReadFile("../../../vectors/refs.json")
	if err != nil {
		t.Fatal(err)
	}
	var v struct {
		Cases []struct {
			Name       string              `json:"name"`
			Refs       []api.Ref           `json:"refs"`
			Vaults     map[string][]string `json:"vaults"`
			Items      []api.EnvItem       `json:"items"`
			Shadowed   []api.EnvItem       `json:"shadowed"`
			Duplicates []string            `json:"duplicates"`
		} `json:"cases"`
	}
	if err := json.Unmarshal(data, &v); err != nil {
		t.Fatal(err)
	}
	if len(v.Cases) == 0 {
		t.Fatal("没有向量")
	}
	for _, c := range v.Cases {
		names := func(id string) []string { return c.Vaults[id] }
		items, shadowed := Expand(c.Refs, names)
		if !reflect.DeepEqual(items, c.Items) || !reflect.DeepEqual(shadowed, c.Shadowed) {
			t.Errorf("%s：展开结果 %v / %v，期望 %v / %v", c.Name, items, shadowed, c.Items, c.Shadowed)
		}
		if dup := Duplicates(c.Refs, names); !reflect.DeepEqual(dup, c.Duplicates) {
			t.Errorf("%s：重名 %v，期望 %v", c.Name, dup, c.Duplicates)
		}
	}
}

func TestNameIn(t *testing.T) {
	pick := api.Ref{Scope: "pick", Items: []api.RefItem{{Name: "A", As: "X"}, {Name: "B"}}}
	if nameIn(pick, "A") != "X" || nameIn(pick, "B") != "B" || nameIn(pick, "C") != "C" {
		t.Fatal("nameIn 不对")
	}
}
