// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

package db

import (
	"encoding/xml"
	"fmt"
	"strconv"
	"strings"
	"time"
)

// An intelligent playlist (djmdPlaylist.Attribute 4) stores no tracks: Rekordbox matches the
// collection against the conditions in djmdPlaylist.SmartList each time it is shown, e.g.
//
//	<NODE Id="-185693195" LogicalOperator="1" AutomaticUpdate="0">
//	  <CONDITION PropertyName="counter" Operator="1" ValueUnit="" ValueLeft="" ValueRight=""/>
//	</NODE>
//
// smartWhere compiles them to a where clause over djmdContent c. An empty value means none: 0
// for numbers, no text, no date or no colour ("Never Played" is counter = '').

type smartList struct {
	Logic      int              `xml:"LogicalOperator,attr"` // 1: all conditions, 2: any
	Conditions []smartCondition `xml:"CONDITION"`
}

type smartCondition struct {
	Property string `xml:"PropertyName,attr"`
	Operator int    `xml:"Operator,attr"`
	Unit     string `xml:"ValueUnit,attr"`
	Left     string `xml:"ValueLeft,attr"`
	Right    string `xml:"ValueRight,attr"`
}

// Condition operators.
const (
	opIs = iota + 1
	opIsNot
	opGreater
	opLess
	opInRange
	opInLast
	opNotInLast
	opContains
	opNotContains
	opStartsWith
	opEndsWith
)

type smartKind int

const (
	smartText smartKind = iota
	smartNumber
	smartDate
	smartColour
	smartMyTag
)

type smartField struct {
	kind smartKind
	expr string
}

func artistOf(col string) string { return "(select Name from djmdArtist where ID = c." + col + ")" }

var smartFields = map[string]smartField{
	"name":           {smartText, "c.Title"},
	"artist":         {smartText, artistOf("ArtistID")},
	"originalArtist": {smartText, artistOf("OrgArtistID")},
	"remixedBy":      {smartText, artistOf("RemixerID")},
	"producer":       {smartText, artistOf("ComposerID")},
	"album":          {smartText, "(select Name from djmdAlbum where ID = c.AlbumID)"},
	"albumArtist": {smartText, "(select a.Name from djmdAlbum al join djmdArtist a on a.ID = al.AlbumArtistID " +
		"where al.ID = c.AlbumID)"},
	"genre":        {smartText, "(select Name from djmdGenre where ID = c.GenreID)"},
	"label":        {smartText, "(select Name from djmdLabel where ID = c.LabelID)"},
	"key":          {smartText, "(select ScaleName from djmdKey where ID = c.KeyID)"},
	"comments":     {smartText, "c.Commnt"},
	"fileName":     {smartText, "c.FileNameL"},
	"mixName":      {smartText, "c.Subtitle"},
	"bpm":          {smartNumber, "c.BPM / 100.0"},
	"duration":     {smartNumber, "c.Length"}, // seconds
	"rating":       {smartNumber, "c.Rating"}, // stars, 0-5
	"counter":      {smartNumber, "c.DJPlayCount"},
	"year":         {smartNumber, "c.ReleaseYear"},
	"stockDate":    {smartDate, "c.StockDate"}, // date added
	"dateCreated":  {smartDate, "c.DateCreated"},
	"dateReleased": {smartDate, "c.ReleaseDate"},
	"grouping":     {smartColour, "c.ColorID"},
	"myTag":        {smartMyTag, ""},
}

// smartWhere compiles an intelligent playlist's SmartList XML to a where clause over
// djmdContent c and its arguments. today anchors "in the last N days / months".
func smartWhere(src string, today time.Time) (string, []any, error) {
	var sl smartList
	if err := xml.Unmarshal([]byte(src), &sl); err != nil {
		return "", nil, fmt.Errorf("reading its conditions: %w", err)
	}
	join := map[int]string{1: " and ", 2: " or "}[sl.Logic]
	if join == "" {
		return "", nil, fmt.Errorf("unknown LogicalOperator %d", sl.Logic)
	}
	if len(sl.Conditions) == 0 {
		return "", nil, fmt.Errorf("it has no conditions")
	}
	var parts []string
	var args []any
	for _, c := range sl.Conditions {
		part, a, err := c.sql(today)
		if err != nil {
			return "", nil, fmt.Errorf("condition %s %d %q: %w", c.Property, c.Operator, c.Left, err)
		}
		parts = append(parts, "("+part+")")
		args = append(args, a...)
	}
	return strings.Join(parts, join), args, nil
}

func (c smartCondition) sql(today time.Time) (string, []any, error) {
	f, ok := smartFields[c.Property]
	if !ok {
		return "", nil, fmt.Errorf("unknown property")
	}
	switch f.kind {
	case smartText:
		return textSQL("lower(coalesce("+f.expr+", ''))", c.Operator, c.Left)
	case smartNumber:
		return numberSQL("coalesce("+f.expr+", 0)", c)
	case smartDate:
		return dateSQL("coalesce(substr("+f.expr+", 1, 10), '')", c, today)
	case smartColour:
		x := "(case when coalesce(" + f.expr + ", '') in ('', '0') then '' else " + f.expr + " end)"
		switch c.Operator {
		case opIs:
			return x + " = ?", []any{c.Left}, nil
		case opIsNot:
			return x + " <> ?", []any{c.Left}, nil
		}
	case smartMyTag:
		id, err := strconv.ParseInt(c.Left, 10, 64)
		if err != nil {
			return "", nil, fmt.Errorf("not a My Tag ID")
		}
		if id < 0 { // stored as a signed 32-bit integer
			id += 1 << 32
		}
		has := "exists (select 1 from djmdSongMyTag t where t.ContentID = c.ID and t.MyTagID = ? " +
			"and t.rb_local_deleted = 0)"
		switch c.Operator {
		case opIs, opContains:
			return has, []any{strconv.FormatInt(id, 10)}, nil
		case opIsNot, opNotContains:
			return "not " + has, []any{strconv.FormatInt(id, 10)}, nil
		}
	}
	return "", nil, fmt.Errorf("unsupported operator")
}

// textSQL matches x (already lower-cased) case-insensitively, like Rekordbox. Both sides are
// folded by SQLite (ASCII only), so they always fold the same way.
func textSQL(x string, op int, v string) (string, []any, error) {
	esc := strings.NewReplacer(`\`, `\\`, `%`, `\%`, `_`, `\_`).Replace(v)
	switch op {
	case opIs:
		return x + " = lower(?)", []any{v}, nil
	case opIsNot:
		return x + " <> lower(?)", []any{v}, nil
	case opContains:
		return x + ` like ? escape '\'`, []any{"%" + esc + "%"}, nil
	case opNotContains:
		return x + ` not like ? escape '\'`, []any{"%" + esc + "%"}, nil
	case opStartsWith:
		return x + ` like ? escape '\'`, []any{esc + "%"}, nil
	case opEndsWith:
		return x + ` like ? escape '\'`, []any{"%" + esc}, nil
	}
	return "", nil, fmt.Errorf("unsupported operator")
}

func numberSQL(x string, c smartCondition) (string, []any, error) {
	num := func(s string) (float64, error) {
		if s == "" {
			return 0, nil
		}
		return strconv.ParseFloat(s, 64)
	}
	lo, err := num(c.Left)
	if err != nil {
		return "", nil, fmt.Errorf("not a number")
	}
	switch c.Operator {
	case opIs:
		return x + " = ?", []any{lo}, nil
	case opIsNot:
		return x + " <> ?", []any{lo}, nil
	case opGreater:
		return x + " > ?", []any{lo}, nil
	case opLess:
		return x + " < ?", []any{lo}, nil
	case opInRange:
		hi, err := num(c.Right)
		if err != nil {
			return "", nil, fmt.Errorf("upper bound %q is not a number", c.Right)
		}
		return x + " between ? and ?", []any{lo, hi}, nil
	}
	return "", nil, fmt.Errorf("unsupported operator")
}

// dateSQL compares x, a YYYY-MM-DD date or ” when unset, as text. An unset date only
// matches "is ”" and "is not <date>".
func dateSQL(x string, c smartCondition, today time.Time) (string, []any, error) {
	date := func(s string) error {
		if s == "" {
			return nil
		}
		_, err := time.Parse(time.DateOnly, s)
		return err
	}
	switch c.Operator {
	case opIs, opIsNot, opGreater, opLess, opInRange:
		if err := date(c.Left); err != nil {
			return "", nil, fmt.Errorf("not a YYYY-MM-DD date")
		}
	}
	switch c.Operator {
	case opIs:
		return x + " = ?", []any{c.Left}, nil
	case opIsNot:
		return x + " <> ?", []any{c.Left}, nil
	case opGreater:
		return x + " > ?", []any{c.Left}, nil
	case opLess:
		return x + " < ? and " + x + " <> ''", []any{c.Left}, nil
	case opInRange:
		if err := date(c.Right); err != nil || c.Right == "" {
			return "", nil, fmt.Errorf("end %q is not a YYYY-MM-DD date", c.Right)
		}
		return x + " between ? and ?", []any{c.Left, c.Right}, nil
	case opInLast, opNotInLast:
		n, err := strconv.Atoi(c.Left)
		if err != nil {
			return "", nil, fmt.Errorf("not a number of %ss", c.Unit)
		}
		var since time.Time
		switch c.Unit {
		case "1", "day":
			since = today.AddDate(0, 0, -n)
		case "2", "month":
			since = today.AddDate(0, -n, 0)
		default:
			return "", nil, fmt.Errorf("unknown unit %q", c.Unit)
		}
		if c.Operator == opInLast {
			return x + " >= ?", []any{since.Format(time.DateOnly)}, nil
		}
		return x + " < ? and " + x + " <> ''", []any{since.Format(time.DateOnly)}, nil
	}
	return "", nil, fmt.Errorf("unsupported operator")
}
