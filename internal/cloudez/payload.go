package cloudez

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// PayloadHash identifica o CONTEUDO que um deploy publica, e existe porque o
// commit do git nao serve para isso.
//
// Duas razoes, em ordem de importancia:
//
//   - nem todo diretorio publicado vive num repositorio git, e exigir um
//     tornava o deploy impossivel fora dele;
//   - mesmo quando ha repositorio, o sha descreve o FONTE. No caminho sem
//     container o que se publica e a saida do build (`dist/`), que o commit nao
//     fixa: o mesmo commit com outra versao do Node produz bytes diferentes e
//     release_id identico. O hash do payload descreve o que de fato foi ao ar.
//
// O contrato que importa: este hash cobre EXATAMENTE o conjunto de bytes que o
// `transfer` envia. Se os dois divergirem o identificador mente — que e pior do
// que nao ter identificador. Por isso a exclusao do `.git` esta duplicada aqui
// com a mesma semantica nao-ancorada do tar, e nao como um filtro aproximado.
type PayloadHash struct {
	Sum   string `json:"content_sha256"`
	Files int    `json:"files"`
	Bytes int64  `json:"bytes"`
}

// Short devolve o prefixo usado como sufixo do release_id. Sete digitos pela
// mesma razao que o git usa sete: cabe na tela e nao colide em escala humana.
func (p PayloadHash) Short() string {
	return p.Sum[:7]
}

// HashPayload percorre localDir e resume o que seria enviado.
//
// O que entra no hash, e por que:
//
//   - o caminho relativo, sempre com barra normal. Sem normalizar, o mesmo
//     projeto hasheado no Windows e no macOS daria resultados diferentes e o
//     identificador deixaria de ser comparavel entre maquinas.
//   - o bit de execucao, e so ele. Permissao de executavel muda o comportamento
//     do que esta no ar e precisa contar; o resto do modo (owner, grupo, umask
//     de quem clonou) varia por maquina sem que o conteudo mude.
//   - o conteudo do arquivo, ou o ALVO do symlink quando for um. O tar preserva
//     symlinks em vez de segui-los, entao seguir aqui hashearia bytes que nunca
//     viajam — e um link quebrado, que o tar transporta sem reclamar, viraria
//     erro de deploy.
//
// O que NAO entra: mtime, dono e grupo. Todos mudam a cada clone do
// repositorio sem que uma linha do projeto tenha mudado, e fariam o hash de um
// mesmo conteudo diferir entre a maquina do desenvolvedor e o CI.
//
// Diretorios vazios sao ignorados, acompanhando o tar, que os transporta mas
// nao os distingue de ausencia depois de extraidos num diretorio de release.
func HashPayload(localDir string) (PayloadHash, error) {
	entries, err := payloadEntries(localDir)
	if err != nil {
		return PayloadHash{}, err
	}

	sum := sha256.New()
	var total int64
	for _, e := range entries {
		exec := "0"
		if e.mode.Perm()&0o111 != 0 {
			exec = "1"
		}

		// O cabecalho por arquivo termina em \x00 e carrega o tamanho: sem um
		// separador que nao pode aparecer num caminho, "ab" + "c" e "a" + "bc"
		// hasheariam igual, e dois conjuntos de arquivos distintos colidiriam.
		kind := "f"
		if e.mode&fs.ModeSymlink != 0 {
			kind = "l"
		}

		var body []byte
		if kind == "l" {
			target, linkErr := os.Readlink(e.path)
			if linkErr != nil {
				return PayloadHash{}, linkErr
			}
			body = []byte(filepath.ToSlash(target))
		}

		if kind == "l" {
			fmt.Fprintf(sum, "%s %s %s %d\x00", kind, e.rel, exec, len(body))
			sum.Write(body)
			total += int64(len(body))
			continue
		}

		f, openErr := os.Open(e.path)
		if openErr != nil {
			return PayloadHash{}, openErr
		}
		info, statErr := f.Stat()
		if statErr != nil {
			f.Close()
			return PayloadHash{}, statErr
		}
		fmt.Fprintf(sum, "%s %s %s %d\x00", kind, e.rel, exec, info.Size())
		n, copyErr := io.Copy(sum, f)
		f.Close()
		if copyErr != nil {
			return PayloadHash{}, copyErr
		}
		total += n
	}

	return PayloadHash{
		Sum:   hex.EncodeToString(sum.Sum(nil)),
		Files: len(entries),
		Bytes: total,
	}, nil
}

// payloadEntry e um arquivo que o deploy publica. Separado do hash para que o
// teste possa comparar este conjunto com o que o `tar` do transfer de fato
// empacota — a duplicacao da regra de exclusao so e segura enquanto alguem
// verifica que as duas concordam.
type payloadEntry struct {
	rel  string // relativo a raiz publicada, sempre com barra normal
	mode fs.FileMode
	path string
}

// payloadEntries lista, em ordem estavel, os arquivos que seriam enviados.
func payloadEntries(localDir string) ([]payloadEntry, error) {
	var entries []payloadEntry

	err := filepath.WalkDir(localDir, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, relErr := filepath.Rel(localDir, path)
		if relErr != nil {
			return relErr
		}
		if rel == "." {
			return nil
		}
		if excludedFromPayload(rel) {
			if d.IsDir() {
				return filepath.SkipDir
			}
			return nil
		}
		if d.IsDir() {
			return nil
		}
		info, infoErr := d.Info()
		if infoErr != nil {
			return infoErr
		}
		entries = append(entries, payloadEntry{
			rel:  filepath.ToSlash(rel),
			mode: info.Mode(),
			path: path,
		})
		return nil
	})
	if err != nil {
		return nil, err
	}

	// A ordem da caminhada depende do sistema de arquivos. Sem ordenar, o mesmo
	// diretorio daria hashes diferentes em maquinas diferentes.
	sort.Slice(entries, func(i, j int) bool { return entries[i].rel < entries[j].rel })
	return entries, nil
}

// excludedFromPayload reproduz o `--exclude .git` do tar do transfer.
//
// A semantica e a NAO-ancorada dos dois tar: o padrao e o nome puro, entao casa
// `./.git` e tambem o `.git` de um submodulo em qualquer profundidade, e nao
// casa `.gitignore` nem `.github/` — que precisam sobreviver ate o servidor.
// Comparar por prefixo comeria os dois.
func excludedFromPayload(rel string) bool {
	for _, part := range strings.Split(filepath.ToSlash(rel), "/") {
		if part == ".git" {
			return true
		}
	}
	return false
}
