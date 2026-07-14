//
//  FileSizeTracker.swift
//  PhotoVaultiCloudSync
//
//  Registra o tamanho (em bytes) gravado para cada arquivo já copiado para
//  a pasta de backup, indexado pelo NOME do arquivo (não pelo localIdentifier
//  do asset — um único asset pode gerar vários arquivos: foto + RAW pareado,
//  vídeo, vídeo de Live Photo).
//
//  ⚠️ POR QUE ISTO EXISTE: o motor de sincronização pula a re-cópia de
//  qualquer arquivo que já exista no destino, confiando que "existe" =
//  "está correto". Uma cópia truncada por queda de energia ou pelo app
//  sendo encerrado no meio da escrita nunca seria detectada — o arquivo
//  truncado ficaria pulado PARA SEMPRE. Comparando o tamanho atual do
//  arquivo no disco com o tamanho registrado no momento em que a escrita
//  terminou, o motor consegue diferenciar "já copiado corretamente" de
//  "corrompido/incompleto" e re-exportar só o segundo caso.
//
//  Separado do `PhotoTracker` (que decide "sincronizado ou não" por
//  localIdentifier, garantindo o one-way) para não misturar essa garantia
//  crítica com uma preocupação diferente — perder este arquivo de tamanhos
//  na pior das hipóteses volta ao comportamento anterior (confia na
//  existência), nunca compromete o one-way.
//

import Foundation

actor FileSizeTracker {

    /// Nome do arquivo (relativo à pasta de destino) → tamanho em bytes no
    /// momento em que a escrita foi concluída com sucesso.
    private var tamanhos: [String: Int64] = [:]

    private let arquivoURL: URL
    private var carregado = false

    init(fileManager: FileManager = .default) {
        let base = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.temporaryDirectory

        self.arquivoURL = base.appendingPathComponent("file_sizes.json", isDirectory: false)
    }

    private func carregarSeNecessario() {
        guard !carregado else { return }
        carregado = true
        guard let dados = try? Data(contentsOf: arquivoURL) else { return }
        // Corrompido/ilegível: começa vazio. Pior caso é voltar a confiar só
        // na existência do arquivo (comportamento anterior a este recurso) —
        // nunca apaga nem compromete o backup já feito.
        tamanhos = (try? JSONDecoder().decode([String: Int64].self, from: dados)) ?? [:]
    }

    private func salvar() {
        guard let dados = try? JSONEncoder().encode(tamanhos) else { return }
        try? dados.write(to: arquivoURL, options: [.atomic])
    }

    /// Tamanho esperado (registrado na última escrita bem-sucedida) para um
    /// nome de arquivo, se houver.
    func esperado(paraArquivo nomeArquivo: String) -> Int64? {
        carregarSeNecessario()
        return tamanhos[nomeArquivo]
    }

    /// Registra o tamanho gravado para um arquivo — chamar logo após a
    /// escrita ser confirmada.
    func registrar(arquivo nomeArquivo: String, tamanho: Int64) {
        carregarSeNecessario()
        tamanhos[nomeArquivo] = tamanho
        salvar()
    }

    /// Remove o registro de um arquivo (ex.: quando ele foi apagado e vai
    /// ser reexportado do zero).
    func esquecer(arquivo nomeArquivo: String) {
        carregarSeNecessario()
        guard tamanhos.removeValue(forKey: nomeArquivo) != nil else { return }
        salvar()
    }
}
