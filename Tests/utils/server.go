package main

import (
	"io/ioutil"
	"math/rand"
	"net/http"
	"sync"
	"sync/atomic"

	"github.com/gin-gonic/gin"

	"github.com/google/uuid"
)

func main() {

	const totalPages = 10000

	var a1 = []byte(`<a href="/bench/`)
	var a2 = []byte(`" />`)

	gin.DefaultWriter = ioutil.Discard
	router := gin.Default()

	linkIDPool := make([]string, 0, totalPages)
	for i := 0; i < totalPages; i++ {
		linkIDPool = append(linkIDPool, uuid.New().String())
	}
	var linkIDPoolLock sync.Mutex

	visitedPages := uint32(0)

	router.GET("/bench/:id", func(ctx *gin.Context) {

		nowVisitedPages := atomic.AddUint32(&visitedPages, 1)

		id := ctx.Param("id")
		println("now:", nowVisitedPages, id)

		newlyLinks := rand.Intn(4) + 1
		body := make([]byte, 0, 1000)

		newIDs := func() []string {
			linkIDPoolLock.Lock()
			defer linkIDPoolLock.Unlock()

			if len(linkIDPool) < newlyLinks {
				newlyLinks = len(linkIDPool)
			}
			newIDs := linkIDPool[len(linkIDPool)-newlyLinks : len(linkIDPool)]
			linkIDPool = linkIDPool[0 : len(linkIDPool)-newlyLinks]
			return newIDs
		}()

		for _, id := range newIDs {
			body = append(body, a1...)
			body = append(body, id...)
			body = append(body, a2...)
		}

		ctx.Data(http.StatusOK, "text/html; charset=utf-8", body)

	})

	router.Run(":1234")

}
