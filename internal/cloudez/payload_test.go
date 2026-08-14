package cloudez

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"testing"
	"time"
)

// escrever monta uma arvore a partir de um mapa caminho->conteudo. Um caminho
// terminado em "/" vira diretorio vazio.
func escrever(t *testing.T, arquivos map[string]string) string {
	t.Helper()
	dir := t.TempDir()
	for rel, conteudo := range arquivos {
		full := filepath.Join(dir, filepath.FromSlash(rel))
		if strings.HasSuffix(rel, "/") {
			if err := os.MkdirAll(full, 0o755); err != nil {
				t.Fatalf("mkdir %s: %v", rel, err)
			}
			continue
		}
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			t.Fatalf("mkdir %s: %v", rel, err)
		}
		if err := os.WriteFile(full, []byte(conteudo), 0o644); err != nil {
			t.Fatalf("write %s: %v", rel, err)
		}
	}
	return dir
}

func hashDe(t *testing.T, dir string) PayloadHash {
	t.Helper()
	h, err := HashPayload(dir)
	if err != nil {
		t.Fatalf("HashPayload(%s): %v", dir, err)
	}
	return h
}

// O contrato central: o hash cobre exatamente o conjunto que o transfer envia.
// Se divergirem, o release_id descreve algo que nao foi ao ar — pior do que nao
// ter identificador. A regra de exclusao esta escrita duas vezes (aqui e no
// tarArgs do cmd/sync) e este teste e o que impede as duas de divergirem.
func TestHashCobreOMesmoConjuntoQueOTar(t *testing.T) {
	if _, err := exec.LookPath("tar"); err != nil {
		t.Skip("tar indisponivel")
	}

	dir := escrever(t, map[string]string{
		"index.html":            "<h1>oi</h1>",
		".gitignore":            "node_modules\n",
		".github/workflows/ci":  "on: push\n",
		".git/HEAD":             "ref: refs/heads/main\n",
		".git/objects/ab/cd":    "binario",
		"vendor/lib/.git/HEAD":  "ref: refs/heads/main\n",
		"vendor/lib/index.js":   "module.exports = 1\n",
		"assets/img/logo.svg":   "<svg/>",
		"docs/.gitkeep":         "",
		"nested/deep/a/b/c.txt": "c",
	})

	// Mesmos argumentos do transfer, menos a compressao: aqui interessa a lista.
	out, err := exec.Command("tar", "-cf", "-", "--exclude", ".git", "-C", dir, ".").Output()
	if err != nil {
		t.Fatalf("tar -c: %v", err)
	}
	listar := exec.Command("tar", "-tf", "-")
	listar.Stdin = strings.NewReader(string(out))
	listagem, err := listar.Output()
	if err != nil {
		t.Fatalf("tar -t: %v", err)
	}

	doTar := map[string]bool{}
	for _, linha := range strings.Split(strings.TrimSpace(string(listagem)), "\n") {
		linha = strings.TrimPrefix(strings.TrimSpace(linha), "./")
		// Diretorios saem com barra final; o hash so considera arquivos.
		if linha == "" || linha == "." || strings.HasSuffix(linha, "/") {
			continue
		}
		doTar[linha] = true
	}

	entries, err := payloadEntries(dir)
	if err != nil {
		t.Fatalf("payloadEntries: %v", err)
	}
	doHash := map[string]bool{}
	for _, e := range entries {
		doHash[e.rel] = true
	}

	for rel := range doTar {
		if !doHash[rel] {
			t.Errorf("o tar envia %q, mas o hash nao o cobre", rel)
		}
	}
	for rel := range doHash {
		if !doTar[rel] {
			t.Errorf("o hash cobre %q, mas o tar nao o envia", rel)
		}
	}

	if len(doHash) == 0 {
		t.Fatal("nenhum arquivo considerado — o teste nao verificou nada")
	}
}

// `.gitignore` e `.github/` precisam sobreviver ate o servidor: a exclusao e por
// nome puro, nao por prefixo. Ja o `.git` de um submodulo, em qualquer
// profundidade, cai — porque o padrao do tar nao e ancorado na raiz.
func TestExclusaoPegaGitEmQualquerNivelMasNaoOsVizinhos(t *testing.T) {
	casos := []struct {
		rel      string
		excluido bool
	}{
		{".git", true},
		{".git/HEAD", true},
		{"vendor/lib/.git", true},
		{"vendor/lib/.git/objects/ab", true},
		{".gitignore", false},
		{".github", false},
		{".github/workflows/ci.yml", false},
		{"src/.gitkeep", false},
		{"agit/x", false},
		{"x/.gitmodules", false},
	}
	for _, c := range casos {
		if got := excludedFromPayload(c.rel); got != c.excluido {
			t.Errorf("excludedFromPayload(%q) = %v, queria %v", c.rel, got, c.excluido)
		}
	}
}

// O identificador so serve se a mesma entrada der o mesmo hash em maquinas
// diferentes. A ordem da caminhada depende do sistema de arquivos, entao o
// mesmo conteudo criado em ordem diferente precisa colidir de proposito.
func TestMesmoConteudoMesmoHash(t *testing.T) {
	a := escrever(t, map[string]string{"a.txt": "um", "b/c.txt": "dois"})
	b := escrever(t, map[string]string{"b/c.txt": "dois", "a.txt": "um"})

	if hashDe(t, a).Sum != hashDe(t, b).Sum {
		t.Error("mesmo conteudo em ordem de criacao diferente deu hashes diferentes")
	}
}

// mtime muda a cada clone do repositorio sem que uma linha do projeto mude. Se
// entrasse no hash, o CI e a maquina do desenvolvedor nunca concordariam.
func TestMtimeNaoEntraNoHash(t *testing.T) {
	dir := escrever(t, map[string]string{"a.txt": "um"})
	antes := hashDe(t, dir)

	passado := time.Now().Add(-72 * time.Hour)
	if err := os.Chtimes(filepath.Join(dir, "a.txt"), passado, passado); err != nil {
		t.Fatalf("chtimes: %v", err)
	}

	if hashDe(t, dir).Sum != antes.Sum {
		t.Error("mudar o mtime mudou o hash")
	}
}

// O bit de execucao muda o comportamento do que esta no ar — um entrypoint que
// perde o +x quebra o container — entao precisa contar.
func TestBitDeExecucaoEntraNoHash(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("modo de arquivo nao e comparavel no Windows")
	}

	dir := escrever(t, map[string]string{"entrypoint.sh": "#!/bin/sh\n"})
	semExec := hashDe(t, dir)

	if err := os.Chmod(filepath.Join(dir, "entrypoint.sh"), 0o755); err != nil {
		t.Fatalf("chmod: %v", err)
	}

	if hashDe(t, dir).Sum == semExec.Sum {
		t.Error("dar +x nao mudou o hash")
	}
}

// Sem um separador que nao pode aparecer num caminho, dois conjuntos distintos
// de arquivos concatenariam para os mesmos bytes. O caso classico: o nome de um
// invade o conteudo do outro.
func TestFronteiraEntreNomeEConteudo(t *testing.T) {
	a := escrever(t, map[string]string{"ab": "c"})
	b := escrever(t, map[string]string{"a": "bc"})

	if hashDe(t, a).Sum == hashDe(t, b).Sum {
		t.Error(`{"ab": "c"} e {"a": "bc"} colidiram`)
	}
}

// Mover conteudo entre arquivos, mantendo os bytes totais, tem de mudar o hash.
func TestConteudoMovidoEntreArquivosMudaOHash(t *testing.T) {
	a := escrever(t, map[string]string{"x.txt": "um", "y.txt": "dois"})
	b := escrever(t, map[string]string{"x.txt": "dois", "y.txt": "um"})

	if hashDe(t, a).Sum == hashDe(t, b).Sum {
		t.Error("trocar o conteudo entre dois arquivos nao mudou o hash")
	}
}

// O tar preserva symlinks em vez de segui-los. Seguir aqui hashearia bytes que
// nunca viajam, e um link quebrado — que o tar transporta sem reclamar — viraria
// erro de deploy.
func TestSymlinkEHasheadoPeloAlvo(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("symlink exige privilegio no Windows")
	}

	dir := escrever(t, map[string]string{"real.txt": "conteudo"})
	if err := os.Symlink("real.txt", filepath.Join(dir, "link.txt")); err != nil {
		t.Fatalf("symlink: %v", err)
	}
	comLink := hashDe(t, dir)

	// Mesma arvore, mas o link vira arquivo comum com o conteudo do alvo.
	copia := escrever(t, map[string]string{"real.txt": "conteudo", "link.txt": "conteudo"})

	if comLink.Sum == hashDe(t, copia).Sum {
		t.Error("o symlink foi seguido: hasheou o conteudo do alvo em vez do caminho")
	}

	// E um link quebrado nao pode falhar: o tar o transporta.
	quebrado := escrever(t, map[string]string{"a.txt": "x"})
	if err := os.Symlink("nao-existe.txt", filepath.Join(quebrado, "orfao")); err != nil {
		t.Fatalf("symlink: %v", err)
	}
	if _, err := HashPayload(quebrado); err != nil {
		t.Errorf("link quebrado virou erro: %v", err)
	}
}

// Diretorio cujo unico conteudo e `.git` nao tem nada publicavel. Quem chama
// precisa conseguir distinguir isso de um deploy legitimo — e o que o Files == 0
// permite, e o cmd/sync usa para recusar.
func TestSoGitNaoTemArquivoPublicavel(t *testing.T) {
	dir := escrever(t, map[string]string{".git/HEAD": "ref: refs/heads/main\n"})

	if h := hashDe(t, dir); h.Files != 0 {
		t.Errorf("Files = %d, queria 0", h.Files)
	}
}

// Files e Bytes vao para o usuario junto do sha; se mentirem, mentem numa tela
// onde alguem decide se o deploy parece certo.
func TestContagemEBytesConferem(t *testing.T) {
	dir := escrever(t, map[string]string{
		"a.txt":   "12345",
		"b/c.txt": "678",
		".git/x":  "ignorado",
	})

	h := hashDe(t, dir)
	if h.Files != 2 {
		t.Errorf("Files = %d, queria 2", h.Files)
	}
	if h.Bytes != 8 {
		t.Errorf("Bytes = %d, queria 8", h.Bytes)
	}
}

// Âncora entre plataformas. As outras propriedades daqui são relativas ("mudar
// X muda o hash"), e todas continuariam valendo se o Windows produzisse uma
// família de hashes inteiramente diferente da do Linux.
//
// Isso não seria detalhe: o release_id sairia diferente para o mesmo conteúdo
// dependendo de quem publicou, e duas releases idênticas passariam por
// distintas — exatamente o que o identificador existe para evitar.
//
// O mesmo valor está no job `windows-build` do CI, que roda o binário no
// Windows sobre esta mesma árvore. Os dois mudam JUNTOS: se você alterar o
// formato do hash, o teste daqui quebra, e o do CI também.
func TestHashDeArvoreConhecida(t *testing.T) {
	const esperado = "03ff8bfa4d33e6cad50a7101e974ef34d6e8ccd51a77fbaacf97b7355cef01fc"

	dir := escrever(t, map[string]string{
		"index.html":      "<h1>oi</h1>",
		"assets/logo.svg": "svg",
		".git/HEAD":       "ref: x",
	})

	h := hashDe(t, dir)
	if h.Files != 2 {
		t.Fatalf("Files = %d, queria 2 (o .git fica de fora)", h.Files)
	}
	if h.Sum != esperado {
		t.Errorf("hash mudou de formato:\n  veio  %s\n  queria %s\n\n"+
			"Se a mudança foi intencional, atualize TAMBÉM o CONTENT_SHA_ESPERADO "+
			"do job windows-build em .github/workflows/test.yml.", h.Sum, esperado)
	}
}

// Short e o que vira sufixo do release_id.
func TestShortTemSeteDigitos(t *testing.T) {
	dir := escrever(t, map[string]string{"a.txt": "um"})
	h := hashDe(t, dir)

	if len(h.Short()) != 7 {
		t.Errorf("Short() = %q, queria 7 digitos", h.Short())
	}
	if !strings.HasPrefix(h.Sum, h.Short()) {
		t.Errorf("Short() = %q nao e prefixo de %q", h.Short(), h.Sum)
	}
}

// Diretorios vazios nao contam: o tar os transporta, mas depois de extraidos num
// diretorio de release eles nao se distinguem de ausencia.
func TestDiretorioVazioNaoMudaOHash(t *testing.T) {
	comum := map[string]string{"a.txt": "um"}
	sem := escrever(t, comum)

	com := escrever(t, map[string]string{"a.txt": "um", "vazio/": ""})

	if hashDe(t, sem).Sum != hashDe(t, com).Sum {
		t.Error("um diretorio vazio a mais mudou o hash")
	}

	// E a lista precisa continuar estavel.
	entries, err := payloadEntries(com)
	if err != nil {
		t.Fatalf("payloadEntries: %v", err)
	}
	nomes := make([]string, len(entries))
	for i, e := range entries {
		nomes[i] = e.rel
	}
	if !sort.StringsAreSorted(nomes) {
		t.Errorf("lista fora de ordem: %v", nomes)
	}
}
