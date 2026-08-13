package cloudez

import (
	"encoding/json"
	"testing"
)

// Regressao. O cloudez-sync carrega o estado nesta struct, muda `status` e
// `transfer_stats`, e grava de volta — e todo campo fora da struct era apagado
// no caminho. Foi assim que o `domain` gravado pelo cloudez_begin_deploy sumia,
// e o cloudez_compose_up falhava depois com "estado do deploy sem dominio" sem
// ter como saber quem o tinha comido.
func TestRoundTripPreservaCamposDesconhecidos(t *testing.T) {
	in := []byte(`{
	  "deploy_id": "dpl_1",
	  "release_id": "20260813T180750Z-abc1234",
	  "environment": "docker",
	  "ref": "abc1234",
	  "status": "awaiting_upload",
	  "root": "site.com.br/www/claude",
	  "ssh": {"host": "h", "user": "u", "port": 22, "path": "p"},
	  "domain": "site.com.br",
	  "futuro": {"aninhado": [1, 2]}
	}`)

	var d Deploy
	if err := json.Unmarshal(in, &d); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	// O que o sync de fato faz com o estado.
	d.Status = "uploaded"
	d.TransferStats = "tar+ssh"

	out, err := json.Marshal(&d)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	var got map[string]any
	if err := json.Unmarshal(out, &got); err != nil {
		t.Fatalf("unmarshal do resultado: %v", err)
	}

	if got["domain"] != "site.com.br" {
		t.Errorf("domain nao sobreviveu ao round-trip: %v", got["domain"])
	}
	if _, ok := got["futuro"]; !ok {
		t.Error("campo desconhecido aninhado nao sobreviveu ao round-trip")
	}

	// Campo conhecido tem de vencer o preservado — senao o sync nao consegue
	// mudar o proprio estado que ele existe para mudar.
	if got["status"] != "uploaded" {
		t.Errorf("status = %v, queria uploaded", got["status"])
	}
	if got["transfer_stats"] != "tar+ssh" {
		t.Errorf("transfer_stats = %v, queria tar+ssh", got["transfer_stats"])
	}
	if got["ref"] != "abc1234" {
		t.Errorf("ref = %v, queria abc1234", got["ref"])
	}
}

// Sem campo desconhecido nao pode aparecer nada novo — em particular, o `extra`
// nao pode vazar como uma chave aninhada no arquivo.
func TestRoundTripSemCamposDesconhecidos(t *testing.T) {
	in := []byte(`{
	  "deploy_id": "dpl_1",
	  "release_id": "20260813T180750Z-abc1234",
	  "environment": "docker",
	  "ref": "abc1234",
	  "status": "awaiting_upload",
	  "root": "site.com.br/www/claude",
	  "ssh": {"host": "h", "user": "u", "port": 22, "path": "p"}
	}`)

	var d Deploy
	if err := json.Unmarshal(in, &d); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	out, err := json.Marshal(&d)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	var got map[string]any
	if err := json.Unmarshal(out, &got); err != nil {
		t.Fatalf("unmarshal do resultado: %v", err)
	}

	// Conjunto escrito a mao, e nao deployKeys(): um teste que pergunta a
	// implementacao o que esperar concorda com ela ate quando ela esta errada.
	known := map[string]bool{
		"deploy_id": true, "release_id": true, "environment": true,
		"ref": true, "note": true, "status": true, "ssh": true,
		"root": true, "transfer_stats": true,
	}
	for k := range got {
		if !known[k] {
			t.Errorf("chave inesperada na saida: %q", k)
		}
	}
}
