# Stateful Service (PowerShell)

Script em PowerShell para monitoramento e autocorreção. Ele foi criado para monitorar serviços críticos do Windows, indo além de uma simples verificação se está rodando.

A ideia nasceu da necessidade de monitorar um serviço do monitor de PDVs, verificando no banco de dados quantos cupons estavam presos sem integrar. Quando o serviço apresentava problemas, o script realiza correções automáticas, dispara alertas via e-mail e gerenciava todo o ciclo de monitoramento sincronizado através de um agendador de tarefas.

---

## Funcionalidades

### Verificação de Saúde Baseada em Métrica
- Consulta uma fila de banco de dados para verificar se as tarefas estão sendo processadas.
- Exemplo: `SELECT COUNT(*) FROM FILA_DE_CUPONS WHERE STATUS = 'PENDENTE'`.

### Verificação em Múltiplos Estágios
1. **Nível 1 (Aviso):**  
   - Se a fila excede um limite configurado, o script aguarda X segundos e verifica novamente, evitando reinícios por picos momentâneos.
2. **Nível 2 (Emergência):**  
   - Se a fila ultrapassa o limite de emergência, o serviço é reiniciado imediatamente.

### Monitoramento Stateful
- **Cooldown:**  
  - Após um reinício, o script cria um arquivo `.cooldown` e não tenta reiniciar o serviço novamente por um período configurável.
- **Ciclo de Alerta Fechado:**  
  - Se a fila continuar alta durante o cooldown, envia um e-mail de **ALERTA** e cria o arquivo `.alert_sent`.
  - Quando a fila retorna ao normal, envia e-mail de **RESOLVIDO** e limpa o flag de alerta.

### Seguro e Configurável
- **Configuração Externa:**  
  - Todas as credenciais, queries SQL, limites e e-mails são carregados de um arquivo `config.json`.
- **Rotação de Logs:**  
  - O script gerencia automaticamente seus próprios arquivos de log, excluindo logs antigos conforme configurado.

---

## Configuração do Agendador de Tarefas

- **Ação:** Iniciar um programa  
- **Programa:** `C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe`  
  *(Para drivers 32-bit como o Oracle Client)*
- **Argumentos:** `-ExecutionPolicy Bypass -File "C:\caminho\completo\para\watchdog.ps1"`
- **Segurança:**  
  - Marcar "Executar com privilégios mais altos"  
  - "Executar estando o usuário conectado ou não"

---

## Tecnologias

- **PowerShell**
- **Banco de Dados SQL** (Testado com Oracle; compatível com SQL Server, MySQL, etc.)
- **JSON** (para configuração segura)
- **SMTP** (para alertas via Gmail / Google Workspace)