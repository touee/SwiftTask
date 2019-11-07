package main

import (
	"io/ioutil"
	"math/rand"
	"net/http"
	"sync/atomic"

	"github.com/gin-gonic/gin"

	"github.com/google/uuid"
)

func main() {

	const MAX = 10000

	var a1 = []byte(`<a href="/bench/`)
	var a2 = []byte(`" />`)

	gin.DefaultWriter = ioutil.Discard
	router := gin.Default()

	count := uint32(0)

	router.GET("/bench/:id", func(ctx *gin.Context) {

		nowCount := atomic.LoadUint32(&count)

		if nowCount > MAX {
			ctx.String(http.StatusNotFound, "")
			return
		}

		id := ctx.Param("id")
		println("now:", nowCount, id)

		r := (rand.Uint32() % 4) + 1
		newCount := atomic.AddUint32(&count, r)

		if newCount > MAX {
			r = r - (newCount - MAX)
		}

		body := make([]byte, 0, 1000)

		for i := int(r); i >= 0; i-- {
			newID := uuid.New().String()
			body = append(body, a1...)
			body = append(body, []byte(newID)...)
			body = append(body, a2...)
		}

		ctx.Data(http.StatusOK, "text/html; charset=utf-8", body)

	})

	router.Run(":1234")

}
