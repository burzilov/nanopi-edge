package mobilevless

import (
	"encoding/base64"

	qrcode "github.com/skip2/go-qrcode"
)

// QRDataURI возвращает data:image/png;base64,... для вставки в <img>.
func QRDataURI(uri string) (string, error) {
	png, err := qrcode.Encode(uri, qrcode.Medium, 220)
	if err != nil {
		return "", err
	}
	return "data:image/png;base64," + base64.StdEncoding.EncodeToString(png), nil
}
