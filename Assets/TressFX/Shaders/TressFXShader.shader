﻿Shader "TressFX/TFXShader"
{
	Properties
	{
	}
	SubShader
	{
		Tags { "RenderType" = "Opaque" "Queue" = "Geometry+100" }
        Pass
        {
			Tags {"LightMode" = "ForwardBase" } 
			ColorMask 0
        	ZWrite Off
        	ZTest LEqual
        	Cull Off
        	
			Stencil
			{
				Ref 1
				CompFront Always
				PassFront IncrSat
				FailFront Keep
				ZFailFront Keep
				CompBack Always
				PassBack IncrSat
				FailBack keep
				ZFailBack keep
			}
			
            CGPROGRAM
            #pragma target 5.0
 
            #pragma vertex vert
            #pragma fragment frag
			#pragma multi_compile_fwdbase
            
            #include "UnityCG.cginc"
            #include "AutoLight.cginc"
            
            // Shader structs
            struct PS_INPUT_HAIR_AA
            {
				    float4 pos	: SV_POSITION;
				    float4 Tangent	: TEXCOORD4;
				    float4 p0p1		: TEXCOORD2;
				    float3 screenPos : TEXCOORD3;
				    float3 worldPos : TEXCOORD5;
					LIGHTING_COORDS(0,1)
			};
			
			//--------------------------------------------------------------------------------------
			// Per-Pixel Linked List (PPLL) structure
			//--------------------------------------------------------------------------------------
			struct PPLL_STRUCT
			{
			    uint	TangentAndCoverage;	
			    float	depth;
			    uint    uNext;
			    half   shadowAmmount;
			    float2	worldPos;
			};
            
            // UAV's
			RWStructuredBuffer<struct PPLL_STRUCT>	LinkedListUAV;
            RWTexture2D<uint> LinkedListHeadUAV;
            
            // All needed buffers
            StructuredBuffer<float3> g_HairVertexTangents;
			StructuredBuffer<float3> g_HairVertexPositions;
			StructuredBuffer<int> g_TriangleIndicesBuffer;
			StructuredBuffer<float> g_HairThicknessCoeffs;
			
			uniform float4 _HairColor;
			uniform float3 g_vEye;
			uniform float4 g_WinSize;
			uniform float g_FiberRadius;
			uniform float g_bExpandPixels;
			uniform float g_bThinTip;
			uniform float g_FiberAlpha;
			uniform float g_alphaThreshold;
			uniform float4 g_MatKValue;
			uniform float g_fHairEx2;
			uniform float g_fHairKs2;
			uniform float4x4 VPMatrix;
			uniform float4x4 MMatrix;
			
			// HELPER FUNCTIONS
			uint PackFloat4IntoUint(float4 vValue)
			{
			    return ( (uint(vValue.x*255)& 0xFFUL) << 24 ) | ( (uint(vValue.y*255)& 0xFFUL) << 16 ) | ( (uint(vValue.z*255)& 0xFFUL) << 8) | (uint(vValue.w * 255)& 0xFFUL);
			}

			float4 UnpackUintIntoFloat4(uint uValue)
			{
			    return float4( ( (uValue & 0xFF000000)>>24 ) / 255.0, ( (uValue & 0x00FF0000)>>16 ) / 255.0, ( (uValue & 0x0000FF00)>>8 ) / 255.0, ( (uValue & 0x000000FF) ) / 255.0);
			}

			uint PackTangentAndCoverage(float3 tangent, float coverage)
			{
			    return PackFloat4IntoUint( float4(tangent.xyz*0.5 + 0.5, coverage) );
			}

			float3 GetTangent(uint packedTangent)
			{
			    return 2.0 * UnpackUintIntoFloat4(packedTangent).xyz - 1.0;
			}

			float GetCoverage(uint packedCoverage)
			{
			    return UnpackUintIntoFloat4(packedCoverage).w;
			}
			
			float ComputeCoverage(float2 p0, float2 p1, float2 pixelLoc)
			{
				// p0, p1, pixelLoc are in d3d clip space (-1 to 1)x(-1 to 1)

				// Scale positions so 1.f = half pixel width
				p0 *= g_WinSize.xy;
				p1 *= g_WinSize.xy;
				pixelLoc *= g_WinSize.xy;

				float p0dist = length(p0 - pixelLoc);
				float p1dist = length(p1 - pixelLoc);
				float hairWidth = length(p0 - p1);
			    
				// will be 1.f if pixel outside hair, 0.f if pixel inside hair
				float outside = any( float2(step(hairWidth, p0dist), step(hairWidth, p1dist)) );
				
				// if outside, set sign to -1, else set sign to 1
				float sign = outside > 0.f ? -1.f : 1.f;
				
				// signed distance (positive if inside hair, negative if outside hair)
				float relDist = sign * saturate( min(p0dist, p1dist) );
				
				// returns coverage based on the relative distance
				// 0, if completely outside hair edge
				// 1, if completely inside hair edge
				return (relDist + 1.f) * 0.5f;
			}
			
			void StoreFragments_Hair(uint2 address, float3 tangent, float coverage, float depth, float shadowAmmount, float2 worldPos)
			{
			    // Retrieve current pixel count and increase counter
			    uint uPixelCount = LinkedListUAV.IncrementCounter();
			    uint uOldStartOffset;
			    
			    // uint address_i = ListIndex(address);
			    // Exchange indices in LinkedListHead texture corresponding to pixel location 
			    InterlockedExchange(LinkedListHeadUAV[address], uPixelCount, uOldStartOffset);  // link head texture

			    // Append new element at the end of the Fragment and Link Buffer
			    PPLL_STRUCT Element;
				Element.TangentAndCoverage = PackTangentAndCoverage(tangent, coverage);
				Element.depth = depth;
			    Element.uNext = uOldStartOffset;
			    Element.shadowAmmount = shadowAmmount;
			    Element.worldPos = worldPos;
			    LinkedListUAV[uPixelCount] = Element; // buffer that stores the fragments
			}
              
            //Our vertex function simply fetches a point from the buffer corresponding to the vertex index
            //which we transform with the view-projection matrix before passing to the pixel program.
            PS_INPUT_HAIR_AA vert (appdata_base input)
            {
            	uint vertexId = g_TriangleIndicesBuffer[(int)input.vertex.x];
			    
			    // Access the current line segment
			    uint index = vertexId / 2;  // vertexId is actually the indexed vertex id when indexed triangles are used

			    // Get updated positions and tangents from simulation result
			    float3 t = g_HairVertexTangents[index].xyz;
			    float3 v = g_HairVertexPositions[index].xyz;

			    // Get hair strand thickness
			    float ratio = ( g_bThinTip > 0 ) ? g_HairThicknessCoeffs[index] : 1.0f;

			    // Calculate right and projected right vectors
			    float3 right      = normalize( cross( t, normalize(v - _WorldSpaceCameraPos) ) );
			    float2 proj_right = normalize( mul( VPMatrix, float4(right, 0) ).xy );

			    // g_bExpandPixels should be set to 0 at minimum from the CPU side; this would avoid the below test
			    float expandPixels = (g_bExpandPixels < 0 ) ? 0.0 : 0.71;

				// Calculate the negative and positive offset screenspace positions
				float4 hairEdgePositions[2]; // 0 is negative, 1 is positive
				hairEdgePositions[0] = float4(v +  -1.0 * right * ratio * g_FiberRadius, 1.0);
				hairEdgePositions[1] = float4(v +   1.0 * right * ratio * g_FiberRadius, 1.0);
			    float fDirIndex = (vertexId & 0x01) ? -1.0 : 1.0;
				float4 worldspacePosition = (fDirIndex==-1.0 ? hairEdgePositions[0] : hairEdgePositions[1]) + fDirIndex * float4(proj_right * expandPixels / g_WinSize.y, 0.0f, 0.0f);
				hairEdgePositions[0] = mul(VPMatrix, hairEdgePositions[0]);
				hairEdgePositions[1] = mul(VPMatrix, hairEdgePositions[1]);
				
				// screen position
				float4 vertexPosition = (fDirIndex==-1.0 ? hairEdgePositions[0] : hairEdgePositions[1]) + fDirIndex * float4(proj_right * expandPixels / g_WinSize.y, 0.0f, 0.0f);
				float4 screenPos = ComputeScreenPos(vertexPosition);
				screenPos.xy /= screenPos.w;
				
				hairEdgePositions[0] = hairEdgePositions[0]/hairEdgePositions[0].w;
				hairEdgePositions[1] = hairEdgePositions[1]/hairEdgePositions[1].w;

			    // Write output data
			    PS_INPUT_HAIR_AA Output = (PS_INPUT_HAIR_AA)0;
			    Output.pos = vertexPosition;
			    Output.Tangent  = float4(t, ratio);
			    Output.p0p1     = float4( hairEdgePositions[0].xy, hairEdgePositions[1].xy );
			    Output.screenPos = float3(screenPos.xy, LinearEyeDepth(Output.pos.z));
			    Output.worldPos = worldspacePosition.xyz;
			    
    			TRANSFER_VERTEX_TO_FRAGMENT(Output);
			    
			    return Output;
            }
			
			// A-Buffer pass
            [earlydepthstencil]
            float4 frag( PS_INPUT_HAIR_AA In) : SV_Target
			{
				float2 screenPos = In.screenPos.xy * _ScreenParams.xy;
				uint2 origScreenPos = screenPos;
				screenPos.y = g_WinSize.y - screenPos.y;
				
			     // Render AA Line, calculate pixel coverage
			    float4 proj_pos = float4( (In.screenPos.x * 2) - 1,
			                               (In.screenPos.y * 2) - 1,
			                                1, 
			                                1);
				
				float coverage = ComputeCoverage(In.p0p1.xy, In.p0p1.zw, proj_pos.xy);
				
				coverage *= g_FiberAlpha;
				
			    // only store fragments with non-zero alpha value
			    if (coverage > g_alphaThreshold) // ensure alpha is at least as much as the minimum alpha value
			    {
			    	float shadowAmmount = SHADOW_ATTENUATION(In);
			        StoreFragments_Hair(origScreenPos, In.Tangent.xyz, coverage, In.pos.z, shadowAmmount, In.pos.xy);
			    }
			    
			    // output a mask RT for final pass  
			    return float4(coverage, coverage, coverage, 1);
			}
            
            ENDCG
        }
		
		// Pass to render object as a shadow collector
	    Pass
	    {
	        Name "ShadowCollector"
	        Tags { "LightMode" = "ShadowCollector" }
	 
	        Fog {Mode Off}
			ZWrite On ZTest LEqual
			
	        CGPROGRAM
	        #pragma vertex vert
	        #pragma fragment frag
	        #pragma multi_compile_shadowcollector
			#pragma target 5.0

	        #define SHADOW_COLLECTOR_PASS
	        #include "UnityCG.cginc"
			
			StructuredBuffer<float3> g_HairVertexTangents;
			StructuredBuffer<float3> g_HairVertexPositions;
			StructuredBuffer<int> g_TriangleIndicesBuffer;
			StructuredBuffer<float> g_HairThicknessCoeffs;
			uniform float4 g_WinSize;
			uniform float g_FiberRadius;
			uniform float g_bExpandPixels;
			uniform float g_bThinTip;

	        struct v2f {
	            V2F_SHADOW_COLLECTOR;
	        };

        	// --------------------------------------
        	// TressFX Antialias shader written by AMD
        	// 
        	// Modified by KennuX
        	// --------------------------------------
	        v2f vert (appdata_base v)
	        { 
	            v2f o;
	            
	        	// Access the current line segment
				uint vertexId = g_TriangleIndicesBuffer[(int)v.vertex.x];
				
			    // Access the current line segment
			    uint index = vertexId / 2;  // vertexId is actually the indexed vertex id when indexed triangles are used
				
			    // Get updated positions and tangents from simulation result
			    float3 vert = g_HairVertexPositions[index].xyz;
			    float3 t = g_HairVertexTangents[index].xyz;
			    fixed ratio = ( g_bThinTip > 0 ) ? g_HairThicknessCoeffs[index] : 1.0f;

			    // Calculate right and projected right vectors
			    fixed3 right      = normalize( cross( t, normalize(vert - _WorldSpaceCameraPos) ) );
			    
			    // g_bExpandPixels should be set to 0 at minimum from the CPU side; this would avoid the below test
			    fixed expandPixels = (g_bExpandPixels < 0 ) ? 0.0 : 0.71;
			    
			    // Which direction to expand?
			    fixed fDirIndex = (vertexId & 0x01) ? -1.0 : 1.0;
			    
			    // Calculate the edge position
			    v.vertex = float4(vert + fDirIndex * right * ratio * g_FiberRadius, 1.0);
	            
	            TRANSFER_SHADOW_COLLECTOR(o)
	            return o;
	        }

	        half4 frag (v2f i) : COLOR
	        {
	            SHADOW_COLLECTOR_FRAGMENT(i)
	        }
	        ENDCG
	    }
	    
	    
		
		// Pass to render object as a shadow caster
		/*Pass
		{
			Name "ShadowCaster"
			Tags { "LightMode" = "ShadowCaster" }

			CGPROGRAM
			#pragma vertex vert
			#pragma fragment frag
			#pragma target 5.0
			#pragma multi_compile_shadowcaster
	            
			#include "UnityCG.cginc"
			
			StructuredBuffer<float3> g_HairVertexTangents;
			StructuredBuffer<float3> g_HairVertexPositions;
			StructuredBuffer<int> g_TriangleIndicesBuffer;
			StructuredBuffer<float> g_HairThicknessCoeffs;
			uniform float4 g_WinSize;
			uniform float g_FiberRadius;
			uniform float g_bExpandPixels;
			uniform float g_bThinTip;
			
			struct v2f
			{ 
				V2F_SHADOW_CASTER;
			};

			v2f vert(appdata_base v)
			{
	            v2f o;
	            
	        	// Access the current line segment
				uint vertexId = g_TriangleIndicesBuffer[(int)v.vertex.x];
				
			    // Access the current line segment
			    uint index = vertexId / 2;  // vertexId is actually the indexed vertex id when indexed triangles are used
				
			    // Get updated positions and tangents from simulation result
			    float3 vert = g_HairVertexPositions[index].xyz;
			    float3 t = g_HairVertexTangents[index].xyz;
			    fixed ratio = ( g_bThinTip > 0 ) ? g_HairThicknessCoeffs[index] : 1.0f;

			    // Calculate right and projected right vectors
			    fixed3 right      = normalize( cross( t, normalize(vert - _WorldSpaceCameraPos) ) );
			    
			    // g_bExpandPixels should be set to 0 at minimum from the CPU side; this would avoid the below test
			    fixed expandPixels = (g_bExpandPixels < 0 ) ? 0.0 : 0.71;
			    
			    // Which direction to expand?
			    fixed fDirIndex = (vertexId & 0x01) ? -1.0 : 1.0;
			    
			    // Calculate the edge position
			    v.vertex = float4(vert + fDirIndex * right * ratio * g_FiberRadius, 1.0);
	            
				TRANSFER_SHADOW_CASTER(o)
				return o;
			}

			float4 frag( v2f i ) : COLOR
			{
				SHADOW_CASTER_FRAGMENT(i)
			}
			ENDCG
		}*/
	}
}
