package main

import (
	"fmt"
	"time"

	"github.com/gocolly/colly"
)

func main() {
	c := colly.NewCollector(
		colly.Async(true),
		colly.MaxDepth(0),
	)

	startTime := time.Now()

	c.Limit(&colly.LimitRule{
		DomainGlob:  "localhost",
		Parallelism: 4,
	})

	c.OnHTML("a[href]", func(e *colly.HTMLElement) {
		e.Request.Visit(e.Attr("href"))
	})

	// c.OnRequest(func(r *colly.Request) {
	// 	fmt.Println("Visiting:", r.URL)
	// })

	c.OnError(func(r *colly.Response, err error) {
		fmt.Println("Request URL:", r.Request.URL, "failed with response:", r, "\nError:", err)
	})

	c.Visit("http://localhost:1234/bench/start")

	c.Wait()

	fmt.Println("time:", time.Now().Sub(startTime).Seconds(), "s")

}
