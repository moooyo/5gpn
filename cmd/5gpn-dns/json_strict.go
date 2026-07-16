package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
)

func decodeStrictJSON(r io.Reader, dst any) error {
	dec := json.NewDecoder(r)
	dec.DisallowUnknownFields()
	if err := dec.Decode(dst); err != nil {
		return err
	}
	var extra any
	if err := dec.Decode(&extra); !errors.Is(err, io.EOF) {
		if err == nil {
			return errors.New("multiple JSON values")
		}
		return err
	}
	return nil
}

func unmarshalStrictJSON(data []byte, dst any) error {
	return decodeStrictJSON(bytes.NewReader(data), dst)
}
