require 'nn'
require 'nngraph'
require 'cutorch'
require 'cunn'
require 'optim'

cmd = torch.CmdLine()
cmd:text()
cmd:text()
cmd:text('Training a simple grid lstm 1D network')
cmd:text()
cmd:text('Options')
cmd:option('-hidden',500,'number of hidden neurons')
cmd:option('-layers',5,'number of layers')
cmd:option('-learning_rate',0.005,'learning rate')
cmd:option('-batch_size',100,'batch size')
cmd:option('-iterations',15000000,'nb of iterations')
cmd:option('-nb_bits',10,'input number of bits')
cmd:option('-eval_interval',1000,'print interval')
cmd:option('-untied_weights',false,'Untie LSTM if true')
cmd:option('-gpu',1,'gpu to use. if 0, cpu')
cmd:text()
params = cmd:parse(arg)

-- gpu activation
local gpu = params.gpu > 0
if gpu then
  ok, cunn = pcall(require, 'cunn')
  ok2, cutorch = pcall(require, 'cutorch')
  gpu = gpu and ok and ok2
end

if gpu then
  print("Using GPU", params.gpu)
  cutorch.setDevice(params.gpu)
else
  print("GPU OFF")
end

-- build model
cell_dim = params.hidden

inputs = {}
table.insert(inputs,nn.Identity()())
m0 = nn.Linear(params.nb_bits, cell_dim)(inputs[1])
h0 = nn.Linear(params.nb_bits, params.hidden)(inputs[1])

forget_lin = nn.Linear(params.hidden,cell_dim)
input_lin = nn.Linear(params.hidden,cell_dim)
candidate_lin = nn.Linear(params.hidden,cell_dim)
output_lin = nn.Linear(params.hidden,cell_dim)

forget_gate_ = nn.Sigmoid()(forget_lin(h0))
input_gate_ = nn.Sigmoid()(input_lin(h0))
candidate_ = nn.Tanh()( candidate_lin(h0) )
output_gate_ = nn.Sigmoid()(output_lin(h0))

m = nn.CAddTable()( { nn.CMulTable()({input_gate_,candidate_}),nn.CMulTable()({forget_gate_,m0}) })
h = nn.Tanh()( nn.CMulTable()({ output_gate_, m }) )

for n=2,params.layers do
  forget_lin_ = nn.Linear(params.hidden,cell_dim)
  if not params.untied_weights then forget_lin_:share( forget_lin, 'weight', 'bias','gradWeight', 'gradBias'  ) end
  forget_gate_ = nn.Sigmoid()(forget_lin_(h))

  input_lin_ = nn.Linear(params.hidden,cell_dim)
  if not params.untied_weights then input_lin_:share( input_lin, 'weight', 'bias','gradWeight', 'gradBias'  ) end
  input_gate_ = nn.Sigmoid()(input_lin_(h))

  candidate_lin_ = nn.Linear(params.hidden,cell_dim)
  if not params.untied_weights then candidate_lin_:share( candidate_lin, 'weight', 'bias','gradWeight', 'gradBias'  ) end
  candidate_ = nn.Tanh()(candidate_lin_(h))

  output_lin_ = nn.Linear(params.hidden,cell_dim)
  if not params.untied_weights then output_lin_:share( output_lin, 'weight', 'bias','gradWeight', 'gradBias'  ) end
  output_gate_ = nn.Sigmoid()(output_lin_(h))

  m = nn.CAddTable()( { nn.CMulTable()({input_gate_,candidate_}),nn.CMulTable()({forget_gate_,m}) })
  h = nn.Tanh()( nn.CMulTable()({ output_gate_, m }) )
end

outputs = {}
table.insert(outputs, nn.LogSoftMax()(nn.Linear( cell_dim + params.hidden , 2)( nn.JoinTable(2)({h,m}) )))

mlp = nn.gModule(inputs, outputs)
---------Functions:-----------
validation_losses,validation_accuracies = {},{}

function generate_data()
  local input = torch.rand(params.batch_size,params.nb_bits):round()
  local target = (input:sum(2) % 2 +1):squeeze()
  if gpu then
    input=input:cuda()
    target = target:cuda()
  end
    return input,target
end

function train() 
  mlp:zeroGradParameters()
  local input,target = generate_data()
  local out = mlp:forward(input)
  local loss = criterion:forward(out, target)
  local gradOut = criterion:backward(out, target)
  mlp:backward(input, gradOut)
  --mlp:updateParameters(params.learning_rate) 
   return loss, gradParameters 
end

function evaluation()
	local loss, accuracy = 0, 0
	local n = math.floor(100/params.batch_size)
	for i=1,n do
		local input,target = generate_data()
		local out = mlp:forward(input)
		loss = loss + criterion:forward(out, target) 
 		accuracy = accuracy + (out[{{},1}]:exp():round() - target + 1):abs():mean() 
	end
  table.insert(validation_losses, loss / n)
  table.insert(validation_accuracies,accuracy / n)
  return loss /n, accuracy / n
end

---------Training:------------
criterion = nn.ClassNLLCriterion()
if gpu then
  mlp = mlp:cuda()
  criterion=criterion:cuda()
end
parameters, gradParameters = mlp:getParameters()
--parameters:uniform(-0.005, 0.005)
config = {
   learningRate = params.learning_rate,
}

for e=1,params.iterations / params.batch_size do
  optim.adagrad(train, parameters, config)
  if e % params.eval_interval == 0 then
    local validation_loss,validation_accuracy = evaluation()
    print("Iteration", e*params.batch_size,"Loss",validation_loss*100,"Accuracy",validation_accuracy*100)
  end
end


torch.save(string.format( "shared_w_accuracies_i%s_lr%s_h%s_lay%s_b%s_nbb%s", params.iterations, params.learning_rate, params.hidden, params.layers, params.batch_size, params.nb_bits), validation_accuracies)
torch.save(string.format( "shared_w_losses_i%s_lr%s_h%s_lay%s_b%s_nbb%s", params.iterations, params.learning_rate, params.hidden, params.layers, params.batch_size, params.nb_bits), validation_losses)
