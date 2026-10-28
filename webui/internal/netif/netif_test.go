package netif

import "testing"

func TestParseDefaultRoute(t *testing.T) {
	cases := []struct{ in, want string }{
		{"default via 192.168.1.1 dev enp1s0 proto dhcp src 192.168.1.148 metric 1002\n", "enp1s0"},
		{"default via 192.168.1.1 dev end0 proto dhcp metric 100\n", "end0"},
		{"default dev ppp0 scope link\ndefault via 10.0.0.1 dev enp1s0 metric 200\n", "enp1s0"},
		{"default dev ppp0 scope link\n", ""},
		{"default dev sb-tun table 2022\n", ""},
		{"", ""},
	}
	for _, c := range cases {
		if got := ParseDefaultRoute(c.in); got != c.want {
			t.Fatalf("%q: got %q want %q", c.in, got, c.want)
		}
	}
}
