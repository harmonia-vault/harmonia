package update

import "testing"

func TestCompare(t *testing.T) {
	order := []string{
		"0.1.1", "v0.1.2-alpha.1", "0.1.2-beta.1", "0.1.2-beta.2", "0.1.2-beta.10",
		"0.1.2-rc.1", "0.1.2-rc.2", "v0.1.2", "0.1.3-beta.1", "0.2.0", "1.0.0-rc.1", "1.0.0",
	}
	for i := range order {
		for j := range order {
			want := 0
			if i > j {
				want = 1
			} else if i < j {
				want = -1
			}
			if got := Compare(order[i], order[j]); got != want {
				t.Errorf("Compare(%s, %s) = %d, want %d", order[i], order[j], got, want)
			}
		}
	}
	if !IsPrerelease("0.1.2-rc.1") || IsPrerelease("0.1.2") {
		t.Error("IsPrerelease")
	}
	if c, err := ParseChannel("beta"); err != nil || c != Beta {
		t.Error("ParseChannel beta")
	}
	if _, err := ParseChannel("nightly"); err == nil {
		t.Error("unknown channel must fail")
	}
}
