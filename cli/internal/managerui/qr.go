package managerui

import (
	"strconv"
	"strings"

	"rsc.io/qr"
)

// qrMatrix 返回二维码的点阵；内容过长无法编码时返回 nil。
func qrMatrix(text string) [][]bool {
	code, err := qr.Encode(text, qr.L)
	if err != nil {
		return nil
	}
	rows := make([][]bool, code.Size)
	for y := range rows {
		rows[y] = make([]bool, code.Size)
		for x := range rows[y] {
			rows[y][x] = code.Black(x, y)
		}
	}
	return rows
}

// qrSVG 把二维码内容画成 SVG（深色方块，透明底），页面把它放进浅色底的方框里。
func qrSVG(text string) string {
	rows := qrMatrix(text)
	if rows == nil {
		return ""
	}
	const quiet = 2
	size := len(rows) + quiet*2
	var b strings.Builder
	b.WriteString(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ` + strconv.Itoa(size) + ` ` + strconv.Itoa(size) + `" shape-rendering="crispEdges"><path fill="#1E1B16" d="`)
	for y, row := range rows {
		for x, on := range row {
			if on {
				b.WriteString("M" + strconv.Itoa(x+quiet) + " " + strconv.Itoa(y+quiet) + "h1v1h-1z")
			}
		}
	}
	b.WriteString(`"/></svg>`)
	return b.String()
}
