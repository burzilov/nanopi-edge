package clash

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

type Client struct {
	Base   string
	Secret string
	HTTP   *http.Client
}

func New(base, secret string) *Client {
	return &Client{
		Base:   strings.TrimRight(base, "/"),
		Secret: secret,
		HTTP:   &http.Client{Timeout: 10 * time.Second},
	}
}

func (c *Client) do(method, path string, body any) ([]byte, error) {
	var rdr io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			return nil, err
		}
		rdr = bytes.NewReader(b)
	}
	req, err := http.NewRequest(method, c.Base+path, rdr)
	if err != nil {
		return nil, err
	}
	if c.Secret != "" {
		req.Header.Set("Authorization", "Bearer "+c.Secret)
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	res, err := c.HTTP.Do(req)
	if err != nil {
		return nil, err
	}
	defer res.Body.Close()
	data, err := io.ReadAll(res.Body)
	if err != nil {
		return nil, err
	}
	if res.StatusCode >= 300 {
		return data, fmt.Errorf("clash_api %s %s: %s: %s", method, path, res.Status, string(data))
	}
	return data, nil
}

func (c *Client) WaitReady(attempts int, delay time.Duration) error {
	var last error
	for i := 0; i < attempts; i++ {
		_, last = c.do(http.MethodGet, "/version", nil)
		if last == nil {
			return nil
		}
		time.Sleep(delay)
	}
	return fmt.Errorf("clash_api недоступен: %w", last)
}

type ProxyGroup struct {
	Name string   `json:"name"`
	Type string   `json:"type"`
	Now  string   `json:"now"`
	All  []string `json:"all"`
}

func (c *Client) GetProxy(name string) (ProxyGroup, error) {
	var g ProxyGroup
	data, err := c.do(http.MethodGet, "/proxies/"+name, nil)
	if err != nil {
		return g, err
	}
	err = json.Unmarshal(data, &g)
	return g, err
}

func (c *Client) SetProxy(group, outbound string) error {
	_, err := c.do(http.MethodPut, "/proxies/"+group, map[string]string{"name": outbound})
	return err
}
