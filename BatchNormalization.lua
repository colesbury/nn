--[[
   This file implements Batch Normalization as described in the paper:
   "Batch Normalization: Accelerating Deep Network Training
                         by Reducing Internal Covariate Shift"
                   by Sergey Ioffe, Christian Szegedy

   This implementation is useful for inputs NOT coming from convolution layers.
   For convolution layers, use nn.SpatialBatchNormalization.

   The operation implemented is:
   y =     ( x - mean(x) )
        -------------------- * gamma + beta
        standard-deviation(x)
   where gamma and beta are learnable parameters.

   The learning of gamma and beta is optional.

   Usage:
   bn = nn.BatchNormalization(N [,eps] [,momentum] [,affine=true], [,inplace=false])

   where
    N = dimensionality of input
    eps is a small value added to the standard-deviation to avoid divide-by-zero.
       Defaults to 1e-5
    momentum is the coefficient controlling the moving average of mean and variance
    affine = enables learnable parameters `weight` and `bias`
    inplace computes output and gradInput in-place

   In training time, this layer keeps a running estimate of it's computed mean and variance.
   The running sum is kept with a default momentum of 0.1 (unless overridden)
   In test time, this running mean/variance is used to normalize.
]]--
local BN,parent = torch.class('nn.BatchNormalization', 'nn.Module')
local THNN = require 'nn.THNN'

BN.__version = 2

-- expected dimension of input
BN.nDim = 2

function BN:__init(nOutput, eps, momentum, affine, inplace)
   parent.__init(self)
   assert(nOutput and type(nOutput) == 'number',
          'Missing argument #1: dimensionality of input. ')
   assert(nOutput ~= 0, 'To set affine=false call BatchNormalization'
     .. '(nOutput,  eps, momentum, false) ')
   if affine ~= nil then
      assert(type(affine) == 'boolean', 'affine has to be true/false')
      self.affine = affine
   else
      self.affine = true
   end
   self.eps = eps or 1e-5
   self.train = true
   self.momentum = momentum or 0.1
   self.running_mean = torch.zeros(nOutput)
   self.running_var = torch.ones(nOutput)
   self.inplace = inplace or false

   if self.affine then
      self.weight = torch.Tensor(nOutput)
      self.bias = torch.Tensor(nOutput)
      self.gradWeight = torch.Tensor(nOutput)
      self.gradBias = torch.Tensor(nOutput)
      self:reset()
   end
end

function BN:reset()
   if self.weight then
      self.weight:uniform()
   end
   if self.bias then
      self.bias:zero()
   end
   self.running_mean:zero()
   self.running_var:fill(1)
end

function BN:checkInputDim(input)
   assert(input:dim() == self.nDim, string.format(
     'only mini-batch supported (%dD tensor), got %dD tensor instead',
     self.nDim, input:dim()))
end

local function makeContiguous(self, input, gradOutput)
   if not input:isContiguous() then
      self._input = self._input or input.new()
      self._input:resizeAs(input):copy(input)
      input = self._input
   end
   if gradOutput then
      if not gradOutput:isContiguous() then
         self._gradOutput = self._gradOutput or gradOutput.new()
         self._gradOutput:resizeAs(gradOutput):copy(gradOutput)
         gradOutput = self._gradOutput
      end
   end
   return input, gradOutput
end

function BN:updateOutput(input)
   self:checkInputDim(input)

   input = makeContiguous(self, input)

   if self.inplace then
      self.output:set(input)
   else
      self.output:resizeAs(input)
   end

   self.save_mean = self.save_mean or input.new()
   self.save_mean:resizeAs(self.running_mean)
   self.save_std = self.save_std or input.new()
   self.save_std:resizeAs(self.running_var)

   input.THNN.BatchNormalization_updateOutput(
      input:cdata(),
      self.output:cdata(),
      THNN.optionalTensor(self.weight),
      THNN.optionalTensor(self.bias),
      self.running_mean:cdata(),
      self.running_var:cdata(),
      self.save_mean:cdata(),
      self.save_std:cdata(),
      self.train,
      self.momentum,
      self.eps,
      self.inplace)

   return self.output
end

local function backward(self, input, gradOutput, scale, gradInput, gradWeight, gradBias)
   self:checkInputDim(input)
   self:checkInputDim(gradOutput)
   assert(self.train == true, 'should be in training mode when self.train is true')
   assert(self.save_mean and self.save_std, 'must call :updateOutput() first')

   input, gradOutput = makeContiguous(self, input, gradOutput)

   scale = scale or 1
   if gradInput then
      gradInput:resizeAs(gradOutput)
   end

   input.THNN.BatchNormalization_backward(
      input:cdata(),
      gradOutput:cdata(),
      THNN.optionalTensor(gradInput),
      THNN.optionalTensor(gradWeight),
      THNN.optionalTensor(gradBias),
      THNN.optionalTensor(self.weight),
      self.save_mean:cdata(),
      self.save_std:cdata(),
      scale,
      self.inplace)

   return self.gradInput
end

function BN:backward(input, gradOutput, scale)
   return backward(self, input, gradOutput, scale, self.gradInput, self.gradWeight, self.gradBias)
end

function BN:updateGradInput(input, gradOutput)
   return backward(self, input, gradOutput, 1, self.gradInput)
end

function BN:accGradParameters(input, gradOutput, scale)
   assert(not self.inplace, 'use module:backward() for in-place')
   return backward(self, input, gradOutput, scale, nil, self.gradWeight, self.gradBias)
end

function BN:read(file, version)
   parent.read(self, file)
   if version < 2 then
      if self.running_std then
         self.running_var = self.running_std:pow(-2):add(-self.eps)
         self.running_std = nil
      end
   end
end

function BN:clearState()
   -- first 5 buffers are not present in the current implementation,
   -- but we keep them for cleaning old saved models
   nn.utils.clear(self, {
      'buffer',
      'buffer2',
      'centered',
      'std',
      'normalized',
      '_input',
      '_gradOutput',
      'save_mean',
      'save_std',
   })
   return parent.clearState(self)
end
